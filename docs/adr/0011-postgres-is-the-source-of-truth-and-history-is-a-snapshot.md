# 0011. Postgres is the source of truth, and history is a snapshot

- Status: Accepted
- Date: 2026-11-24

## Context

Twelve earlier decisions each stated what the database must be able to store, and none of them fixed the things that make a schema a schema: where a key comes from, whether a conversation has messages or answers, whether chunk text lives in one store or two, and what a foreign key is allowed to do to a citation when its document is deleted.

Three facts from those decisions turned out to determine most of the shape.

**Verification works in canonical-markdown offsets.** A citation is not a chunk id with a quote attached; it is a range into one serialized rendering of one document, and the span gate locates the generator's quote inside it. So the canonical markdown has to be addressable by id, and the chunk's own text has to be a slice of it rather than a parallel extraction that merely looks similar.

**The carried tier must hydrate without a vector store.** A follow-up re-admits chunks an earlier answer cited, and the memory decision requires that to work from Postgres alone, because a pinned chunk was never retrieved and a Qdrant outage must not turn every follow-up into `insufficient_support`.

**A citation has to outlive its source.** Deleting a document is a normal operation; a conversation that cited it is history, and its claims, verdicts and confidence keep the values they shipped with.

## Decision

**An Account, not a user.** The table is `accounts`, and `owner_id` on every tenant-scoped table references it. The glossary's term is Account, and the system has no other identity to distinguish it from.

**An Answer is the turn, so there is no `messages` table.** A Conversation is an ordered sequence of Answers, the person's question is a column on the Answer, and claims, verdicts and confidence hang off that row. A role-tagged message table would have made every one of those relationships point at something that is not the Answer.

**Postgres owns chunk display text; canonical markdown is the only ground truth.** `document_content` holds the parse artifact in its own table so the polled status row stays narrow, and `chunks.text` is stored *as a verified slice* of it — ingestion asserts byte equality before the row exists. Qdrant's payload `text` is a projection rebuilt from these rows, never the other way round, and the Qdrant payload is not a source of truth for anything Postgres also stores.

**Keys: `uuidv7()` from the database, with three exceptions.** Every domain id a client can name, address or page by defaults to `uuidv7()`, so a worker, a `psql` session and the API all get the same time-ordered ids and cursor pagination is honest without a second ordering column. Chunks are `uuid5(document_id, chunker_version, chunk_index)` — deterministic, equal to the Qdrant point id, so re-embedding overwrites. Answers are allocated app-side, because `answer_started` carries an id before any row exists. Usage rows take a `bigserial`, because nothing addresses one — see the amendment at the foot of this ADR.

**Live edges cascade; history rows are snapshots.** Everything owned by an Account cascades with it. `model_calls.owner_id` nulls instead, so a deleted Account does not erase the month it spent. Citations and evidence rows carry `chunk_id` and `document_id` as **plain columns with no foreign key**: they are records of what an answer was given, and a live FK would force every document deletion to rewrite history. Verdicts belong to a `verification_runs` row rather than to a citation, so re-derivation after a threshold change appends a run instead of mutating the verdict an answer shipped with. Claim state is derived from citation verdicts, never stored.

**The scorer writes down its own constants.** An Answer persists its confidence version, band cut points, the gate ids applied, and a `confidence_params` blob holding every constant used, so re-deriving a band years later does not depend on a code table that must never be pruned.

**An Answer row is written once, at completion.** It does not exist during generation, which makes the API's three cases — delivered, interrupted, never happened — properties of the data rather than of a status column. In-flight state and the idempotency key live in `answer_requests`, which exists from admission and is the only thing that can hold "one answer per conversation" as a constraint.

**Tenancy is one column and no row-level security.** `owner_id` is denormalised onto documents, conversations, answers, requests and the ledger, so a tenant predicate is always one column. `chunks` deliberately carries none: every read of a chunk already joins `documents` for its status, and that join is where the tenant check happens, so a copy on the chunk would guard nothing. RLS was rejected because the vector store cannot be protected by it — the filter builder remains the real boundary — while it would add a per-transaction GUC to every pooled connection and a bypass path for the admin and worker roles.

## Considered Options

- **`messages` with a role column**, and `answers` as a view or a corollary of it — the conventional chat shape, and it puts claims and verdicts on a row that is not the turn the rest of the system reads.
- **Chunk text only in Qdrant** — one copy, one write; makes the span gate a network call, makes carried chunks depend on the vector store, and makes a deleted document's citations unrenderable.
- **Text derived from `document_content` at read time** — no duplication at all, but every citation render and every verifier batch re-slices a megabyte of markdown.
- **`bigserial` primary keys** — smaller indexes; leaks volume, and forces a second column for the ordering the cursor needs.
- **Client-supplied or pre-generated UUIDv4 answers** — no ordering, worse insert locality, and the id would still have to be allocated before the row.
- **Nullable FKs with `on delete set null` on citations and evidence** — DB-enforced, and it turns deleting a document into a write across every citation that ever pointed into it.
- **Storing claim state alongside citation verdicts** — one fewer derivation; two copies of a fact that the live stream and the stored read must agree on.
- **Thresholds duplicated per verdict row** — no run table; leaves `running`, `degraded` and elapsed time with nowhere to live but the answer row.
- **RLS with `set local app.tenant_id`** — catches a forgotten predicate; protects one of the two stores, and costs a GUC on every connection plus a bypass role.
- **Postgres enum types** — typed, and every new status value becomes `ALTER TYPE` on a live table.
- **A `locked_until` column on `login_attempts`** — simpler read, and a lock that can drift from the counts that justify it.

## Consequences

- **One write path per artifact, and very little updating.** Answers are inserted at completion; claims, citations, evidence and verdicts are insert-only; `model_calls` is append-only. The only UPDATEs in the schema are a document's ingestion progress, a session's `last_seen_at`, an answer's confidence columns once verification resolves, and an admission settling — plus the reindex's per-document generation rewrite, which is the amendment below.
- **Deleting an Account is an unrecoverable purge.** Its documents, chunks, conversations, answers, claims, citations, evidence and verdicts all go. Whether the product offers that or only a disable flag is the deactivation ticket's decision; the schema expresses both, and the second needs one nullable column.
- **A citation can point at a chunk that no longer exists.** That is the price of history surviving deletion: verification fails closed, rendering uses the snapshot, and a carried chunk whose row is gone is silently dropped.
- **An in-flight Answer that a process crash interrupts leaves nothing behind** but its usage rows. There is no resumable generation, by design — the alternative is a streaming status and half-answered rows.
- **Postgres ≥ 18 is now required**, and every test path needs a real Postgres: no SQLite fallback, because `uuidv7()`, partial indexes and `jsonb` are load-bearing.
- **Tenancy is a convention with two backstops** — one `owner_id` column everywhere, and a CI check that every query against a tenant table carries it. A forgotten predicate is a code-review failure, not a database error.
- **The schema is the spec.** [`docs/schema/0001-initial.sql`](../schema/0001-initial.sql) is the source for `0001_initial`, and the rules a CHECK cannot express — the canonical-slice equality, tenant agreement between parent and child, the uuid5 point id, and the retention windows — are listed at its foot.
- Two glossary terms entered the language with this decision: **Indexing generation** and **Verification run**. `answer_requests` deliberately did not: it is idempotency bookkeeping, not a domain concept.

## Amendment (same day, after review)

A review pass over the schema removed seven indexes and six columns and fixed two defects. No decision above moved, but three of the cuts are worth recording because they are the ones a reader would otherwise re-add:

- **`answers.id` lost its `DEFAULT uuidv7()`.** The id is allocated before the row exists so that `answer_started` can carry it; a database default would let a writer that omitted the id mint a second one that silently disagrees with the id the client already holds. `chunks.id` has no default for the same reason.
- **`chunks.owner_id` went.** It was added for "a tenant predicate is always one column", and no read of a chunk is ever a standalone read: hydration is by primary key, and the retrieval gate and carried-tier check both need the document's status, which is a join. A copy that no query reads only creates an invariant to maintain.
- **`citation_verdicts` lost its copy of the matched span**, and `answers` lost `band_cut_points`. Both were second stores of a value that already exists one row away — the citation's located offsets, and `confidence_params`' cut points — and a second store can only diverge.

Also removed: `sessions.ip` and `user_agent` (no reader, and personal data with no retention rule attached), `accounts.updated_at` (no writer), and seven indexes that either duplicated another index's leading columns or served no query the map defines. `answers_band_shape` was relaxed so `insufficient_support` may have no base, because an empty evidence set makes the support share 0/0 and the alternative was inventing a zero.

## Amendment — 2026-11-24: what "current generation" means during a reindex

Rule 4 of the schema's comment list says a chunk's four embedding columns "equal the document's
current indexing generation and name the collection the vector was written to".
[ADR 0014](./0014-reindex-builds-beside-the-serving-index.md) rewrites those columns per document
while a run is in flight, so "current" needs a meaning that survives a library which is deliberately
mixed — and that meaning was never written down, because until a reindex existed no two generations
could be live at once.

**"Current" is per document, and it is the generation the document's vectors were last *fully*
written under.** It is not "the generation the alias resolves to". Four properties follow, and they
are what the write path asserts:

- **A document's rows move together, once.** Its four columns and every one of its chunks' move in the
  same transaction, and only after that document's target points are all active and counted. There is
  no instant at which a document's row names a generation with a half-written vector set, and none at
  which a chunk and its document disagree.
- **Until that transaction commits, the rows describe the vector retrieval is using.** In a shadow run
  the target already holds the new vectors while the row still names the source collection — the
  collection an answer is actually reading — so the columns are never a claim about a collection
  nothing reads.
- **Across the library the columns differ, document by document**, exactly as ADR 0014 says. Code that
  needs "what is being served" asks the alias; code that needs "which generation this document belongs
  to" reads the columns. They answer different questions, and no query may stand one in for the
  other — which is also why the readiness gate reads `documents.status`, not these columns.
- **A completed run's columns are ahead of the alias until the flip.** In the `verifying` window every
  document has moved and no query has: that is a run-level fact, held by the open `reindex_runs` row
  and its `state`, not by any column.

### The enumerated UPDATEs gain a fifth entry

The "very little updating" consequence above lists four UPDATE paths. A reindex adds a fifth, and it
is the only one that writes many rows at a time:

- **A reindex rewrites one document's generation, per document, in one transaction.** For an
  embed-only run that is the four embedding columns on the document and on all of that document's
  chunk rows. For a re-chunk it adds `chunker_version`, `chunk_config_hash` and `chunks_total` on the
  document, and the new generation's chunks are *inserts* under new uuid5 ids, never updates — which
  is the coexist-as-generations rule above doing its job. Scope is one document, so the transaction
  has a bound and a corpus-wide figure never appears in a single statement: a run moves documents one
  at a time and each is independently correct.

A rollback (`reindex rollback`, ADR 0014) is the same statement in reverse, from the source generation
the run recorded — still one document at a time, and only while the superseded collection exists.

The schema's rule 4 comment now carries the short form of this definition, so the spec and this
amendment say the same thing. Nothing else in this ADR moves: answers, citations, evidence and
verdicts stay insert-only, and a reindex touches no history row, because what keeps a citation
legible is its snapshot, not the chunk it once pointed at.

## Amendment — 2026-11-25: the deactivation ticket is closed

The consequence above left "whether the product offers that or only a disable flag" to a separate
decision. [ADR 0015](./0015-deactivation-is-reversible-and-deletion-purges-two-stores.md) settled it:
**both exist.** `deactivated_at` on `accounts` is the reversible half and deletion is the row's
absence, so one nullable column expresses the whole state machine and `status` never grows a `deleted`
value. A purge removes the relational rows in one transaction and the vectors through a job deferred
inside it. The one rule the schema cannot constrain — at least one Account with
`role = 'admin' and deactivated_at is null` — joins the comment list at the foot of the file.

## Amendment — 2026-11-25: the ledger's key is a `bigserial`

The rule above claimed two exceptions and the schema has always had three: `model_calls.id` is a
`bigserial`, as [ADR 0008](./0008-price-every-call-and-gate-spend-before-the-call.md) drew it.
Naming it beats changing it, because the reason `uuidv7()` exists does not reach this table —
**nothing addresses a usage row by id.** No route takes one, no table references one, and the ledger
is never paged by it: it is summed by `(owner_id, scope, created_at)` for a month and by
`(scope, created_at)` for the deployment, and looked up by `(subject_kind, subject_id)` when
something needs to know which calls produced an artifact. The id identifies a row inside its own
table and nothing else.

The rejection of `bigserial` under Considered Options still stands, and is why this is an exception
rather than a policy change: it leaks volume, and it forces a second column for the ordering a
cursor needs. A ledger needs neither — sequence order *is* insert order, which is the only order it
has, and an admin reading the usage table already sees the deployment's call counts, so volume is
no secret there. Meanwhile this is the one table that grows a row per provider call, where 8 bytes
against 16 is the whole difference and the table is the largest by row count in the system.
