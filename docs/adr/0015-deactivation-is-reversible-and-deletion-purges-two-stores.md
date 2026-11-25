# 0015. Deactivation is reversible; deletion purges two stores

- Status: Accepted
- Date: 2026-11-25

## Context

Three facts decided the shape.

**Sessions were already revocable, and that answers a different question.** [ADR 0005](./0005-accounts-are-invite-only-and-auth-runs-in-the-app.md) can end "stop using this deployment now" at any moment, and it deliberately left the data alone. An Account that should no longer *be* is a separate operation, and the two are routinely confused: suspending someone is not the same act as destroying what they made.

**Everything an Account owns already cascades, and one thing deliberately does not.** [ADR 0011](./0011-postgres-is-the-source-of-truth-and-history-is-a-snapshot.md) makes live edges cascade with the Account and makes `model_calls.owner_id` null instead, "so a deleted Account does not erase the month it spent". The schema can already express a purge in one statement. What it cannot express is the half of the data that lives outside Postgres.

**The vector store is not in the transaction.** Qdrant points are a projection of `chunks` rows, but they are deleted by HTTP calls, and [ADR 0014](./0014-reindex-builds-beside-the-serving-index.md)'s rule for a deleted document — purge "whatever is served and whatever is building" — is a rule about two stores that cannot commit together. A deletion that commits its rows and then fails to reach Qdrant leaves points nothing can render but a later flip can serve.

## Decision

### Three states, and deletion is the row's absence

`active`: the row exists and `deactivated_at` is null. `deactivated`: the row exists and the column is set. `deleted`: there is no row.

Deliberately not a `status` column with `deleted` among its values. Deletion *is* the row's absence, so a stored `deleted` would be a tombstone contradicting the purge it claimed to have completed. One nullable column expresses the whole machine, which is what ADR 0011 meant by "the second needs one nullable column".

**Deletion is immediate and terminal, with no grace window.** There is no mail delivery to announce a pending deletion; a "pending deletion" state would be a fourth state needing its own reaper and its own render inside a UI that already carries three answer states; and a flag retained for thirty days is a retention promise the product cannot keep honestly. The undo is the nightly backup, which the runbook already owns — and the runbook now says plainly that restoring one resurrects the documents with the Account, because the restore path is `reindex --all` over Postgres chunk text.

### Deactivation changes access, and nothing else

A deactivated Account keeps its documents, chunks, vectors, conversations, answers and verdicts, indefinitely. No sweep task, no Qdrant write, no reindex interaction, no filter predicate: **the retrieval filter builder keeps its two predicates** (`owner_id`, `is_active`) because it never learns about Account state at all.

Auto-purging after a window was rejected because it silently converts a suspension into a deletion — the precise ambiguity the state machine exists to remove. A deactivated Tenant costs disk and nothing else: it cannot sign in, so nothing can query it.

An ingestion already queued for a deactivated Account's document still finishes, and an Answer already streaming still completes: suspension is about access, not about discarding work already paid for. Both are bounded and already half-done. Re-activation restores sign-in and nothing else — the sessions were revoked at deactivation and are not revived.

### A purge is two stores, and the queue is the marker

The Postgres half is **one transaction**: the Account row goes, and sessions, password resets, documents, the parse artifact, chunks, conversations, answers, claims, citations, evidence, verdicts and verification runs cascade with it, while `invites.created_by`/`used_by` and `model_calls.owner_id` null out as ADR 0011 already specifies.

The Qdrant half is a **`purge_account` job deferred inside that same transaction**. Procrastinate defers jobs transactionally — ADR 0001's upload path is exactly this shape — so the intent to purge vectors commits if and only if the Account is really gone. That is what makes the second half crash-safe without a bookkeeping table. ADR 0001 already rejected a hand-rolled job table because "we would own retry, backoff and stuck-job recovery, the parts most likely to be wrong"; a purge ledger with a `collections` array, a `completed_at` and its own retention task would have owned all three, plus a reaper for the failure it was meant to prevent.

The job resolves its targets **at run time** — the alias target, plus any open reindex run's target — which is ADR 0014's rule applied to an Account instead of a document. Storing collection names would be a second copy of something the alias and the run row already say, and it could only go stale across a flip. The delete by `owner_id` filter is index-backed: ADR 0002 indexes `owner_id` as `is_tenant`, and strict mode rejects filters on unindexed fields.

The delete request returns **`204` at commit** and does not wait for the vectors. The instant the row is gone no Session can resolve to the Tenant, so its points are already unreachable; blocking a public request on a second store to reach a state the client cannot observe is coupling this design avoids everywhere else.

Retry is error-classified with **no attempt ceiling**: connection errors and 5xx back off to a capped hourly retry that never gives up, because an abandoned intent strands points a later flip would serve; a `404 collection does not exist` is a **success**, because there is then nothing to delete.

### Deletion does not race the stream

An Answer row is written once, at completion, with a foreign key to its Account. A deletion landing while an Answer streams makes that write fail: the Answer cannot exist because its owner no longer does.

A pre-check in front of the deletion — `409 answer_in_progress`, a code [ADR 0009](./0009-serve-rest-with-sse-over-fetch.md) already defines — was drafted and **cut, because it cannot close the window it targets.** A stream can begin between the check and the commit; once the commit lands the sessions are revoked and no new stream can start, but one that began in the gap still exists. A gate that narrows an unavoidable failure path leaves the failure path, and this one would have bought a rare refusal in exchange for nothing.

So deletion wins, and the write path treats a vanished owner as a pre-persist failure: the FK violation is caught, one `answer_not_persisted` line is logged with `reason=owner_gone`, no Answer row exists, and the connection closes. ADR 0009's "exactly one terminal event" is a promise about an Answer, and here there is none — the shape it already accepts for "a break before the first token leaves no Answer at all". No error code joins the closed recorded set, because there is no `answer_requests` row left to record one on.

### Authority, and the one invariant that cannot break

Deactivate and reactivate are **admin-only**, including of another admin. Delete is available to the Account itself from the account page, and to an admin from `/admin`.

**The deployment cannot deactivate or delete its last active admin**, for the same reason `admin create` refuses to run twice: that invariant is what keeps the deployment reachable. It is enforced inside the transaction that performs the change, with the live admin rows locked (`select … for update`), so two admins deactivating each other serialise and the second is refused. A `CHECK` cannot say "at least one row", and a count read before the write would be a check rather than an invariant.

A member may not deactivate themselves: deactivation is a moderation act, and a member who wants out deletes. Self-deletion re-enters the password and needs a typed confirmation; the operator path needs `--yes`.

### One chokepoint, and what a deactivated person is told

Account state is read in exactly one place: ADR 0005's deny-by-default identity resolver. Every route inherits the refusal, and the worker, the reindex and the filter builder never learn the term.

A correct password for a deactivated Account gets its own **`403`**, "this account has been deactivated", rather than a generic credential failure: the password already proved possession, so the distinct answer is not an enumeration oracle, and a person who has just been suspended deserves to know the difference between a wrong password and a wrong state. The copy says *deactivated*, the domain term, because a second word for one state is how a glossary starts to rot.

### The email still identifies a person; deletion is what frees it

`unique (lower(email))` is unchanged. A deactivated Account keeps its address reserved, and a deleted Account's address frees itself because the row is gone. A partial unique index over active rows was rejected: two Accounts on one address, and `email` stops identifying a person across the invite audit trail and the `login_attempts` key.

The consequence lands at mint time — an Invite for an address held by a deactivated Account is **refused when it is minted**, naming the deactivated Account, instead of minting an invite whose redemption fails with a deliberately opaque "invalid invite".

### What survives a purge

Two things, and both are facts about the deployment rather than about the person: the **usage rows**, with `owner_id` nulled, so the month and the deployment's monthly ceiling stay summable; and the **Invite** that admitted them, with `used_by` nulled, so "an invite was spent" survives.

Answers, claims, citations, evidence, verdicts and confidence records go with the Account, because they hold its questions and its documents' text, and no anonymised form of them is kept. A deleted Account's contribution to a published eval figure disappears; eval rows carry `scope = 'eval'`, are owned by nobody, and are unaffected.

## Considered Options

- **Two states only (active/deleted)** — one less column and one less refusal path; a suspension then means destroying data to stop access, which forces an admin to choose between a security response and data loss.
- **A `status` enum holding `deleted`** — a queryable tombstone; contradicts the purge, because the row it lives on must be gone.
- **Soft delete with a thirty-day window** — recoverable by the person; a fourth state with its own reaper, its own render, and a retention promise the product cannot keep without announcing anything.
- **Qdrant-first purge** — no window in which a live Account has no vectors; a crash leaves a live, signed-in Account whose documents silently retrieve nothing, the worst of the available failures.
- **A `account_purges` ledger plus a sweep task** — an explicit record and a thirty-day audit row; re-implements deferral atomicity, retry, backoff and lost-job recovery that ADR 0001 already owns, plus a second reaper for the failure it was meant to prevent.
- **A synchronous Qdrant purge inside the request** — the client sees a fully purged state; blocks a public request on a second store for a state no client can observe, and still needs the retry path for when it fails.
- **Sweep-reconciled orphan points by facet-diffing `owner_id`** — no marker at all; a full-collection scan every hour to clean up failures a transactional defer prevents, and a facet over a large library is the heaviest query in the system.
- **A pre-check against in-flight Answers** — cannot close its own window, so it adds a rare refusal and keeps the failure path.
- **A partial unique index over active Accounts** — frees a suspended person's address; puts two Accounts on one address, and `email` stops being a stable identity for the audit trail and the login backoff key.
- **Rewriting a deleted Account's email to a tombstone first** — unnecessary: the row goes, and the address is free by construction.
- **A separate `settings` page for self-deletion** — a tenth UI surface for one form, when the account page already exists for password change.
- **A database trigger enforcing one live admin** — the database's own guard; a trigger the application must also obey and explain, for one invariant on a rare operation.
- **Generic `invalid credentials` for a deactivated Account** — no state disclosure; a `403` after a verified password is not an oracle and is the only honest answer.

## Consequences

- **`accounts` gains one nullable column**, `deactivated_at`, and **no index**: it is read either by primary key (the identity resolver) or over a table the size of the invite list (`/admin`).
- **No new table and no new retention task.** The queue carries the purge, and the schema's retention list is unchanged.
- **Two glossary terms** — **Deactivated account** and **Purge**.
- **ADR 0009 gains a documented exception**: a stream whose Account is deleted persists no Answer and ends by closing the connection, which is the shape it already accepts for a break before the first token.
- **An FK violation is control flow on exactly one path**, deliberately: the completion write catches it, logs `reason=owner_gone`, and ends the request. The alternative was a pre-check that could not close its own window.
- **Deletion is undoable only by the operator, not the product**, and the runbook says so: restore the nightly backup, then `reindex --all`, and the Account and its documents return together.
- **A deactivated Account's data is invisible rather than absent**, so a backup or a `pg_dump` still contains it long after the person stopped using the deployment. That is the honest cost of a reversible state, and it is why deletion — which actually removes it — is the only answer to "I want it gone".
- **`/admin` grows state, not a surface**: deactivated Accounts are listed with a badge and their spend intact, because the money was really spent and the deployment ceiling really counted it.
