# 0014. Reindex beside the serving index, and publish by moving one alias

- Status: Accepted
- Date: 2026-11-24

## Context

Every retrieval decision so far assumed a reindex existed somewhere. Chunks carry `chunker_version`,
`chunk_config_hash` and the four `embedding_*` columns, and collection names are keyed on the
embedding identity, so a stale vector is *detectable* — but nothing yet said what the system does
once it has detected one. Two earlier decisions had already begun depending on it:
[ADR 0012](./0012-one-compose-stack-with-a-caddy-overlay.md) makes the restore path *be* a reindex
("rebuild every vector from Postgres chunk text, without the PDFs, without re-parsing"), and
[ADR 0011](./0011-postgres-is-the-source-of-truth-and-history-is-a-snapshot.md) lets carried chunks
hydrate from Postgres so a follow-up survives a vector-store outage.

Three facts decided most of the shape.

**One embedder, one model.** `tei` is one container pinned to one `--model-id`. A migration therefore
cannot produce old and new vectors at the same time; whatever the deployment is configured for is the
only thing it can embed. Dual-writing two collections would need a second model server, which the
topology in ADR 0012 deliberately does not have.

**A collection's shape is immutable; an alias is not.** Vector size, distance and the tenant HNSW
graph are fixed at collection creation, so a new model is necessarily a new collection — Qdrant's
1.18+ named-vector route (add `dense_v2`, backfill with `update_vectors`, switch the query's `using`)
only helps when dimensions happen to match, and it would break the invariant that a chunk's embedding
columns name the collection its vector was written to. What *is* mutable is an alias:
`POST /collections/aliases` applies a `delete_alias` and a `create_alias` in one request, atomically,
so a reader either sees the old collection or the new one and never an alias that is missing.

**A chunker bump is not a model change.** New `chunker_version` means new uuid5 point ids inside the
*same* collection, because the identity did not change ([ADR 0002](./0002-tenant-partitioned-hybrid-retrieval-without-sparse-vectors.md)).
That case cannot ride an alias, so this decision has to answer two cutovers, not one.

## Decision

### Two cutovers, one driver

- **Embedding change — build beside, flip the alias.** The target collection has a different name.
  The run fills it while the serving collection answers every query; one atomic alias batch
  publishes it; the superseded collection is kept until an operator retires or rolls back.
- **Chunker change — rebuild in place, per document.** New chunks land staged, are activated, are
  verified by filtered count, and only then is the superseded generation deactivated. This is
  ingestion's existing protocol, reused. Qdrant offers no call that moves two generations of one
  document at once, so the two updates leave a window of one round trip in which both generations are
  active: that document can contribute up to twice its chunks to a single prefetch. It cannot produce
  a wrong answer — both generations are complete documents — and the window never outlives the job,
  because the membership row is marked `done` only after the retire update lands (see step 6). The
  other ordering would trade the same window for a hole in which the document is briefly absent, which
  is worse for the person asking.

The run **derives** which it is rather than recording it: a shadow build when its target collection
differs from the one the alias pointed at when the run opened, an in-place rebuild when they are the
same. The two names already say it, and a stored mode could only ever disagree with them.

A library mid-reindex is therefore **mixed per document, never per chunk**: each document is
internally consistent, and the corpus converges document by document.

### The collection name carries the identity *and* the revision

```
chunks__{provider}__{model}__{dims}__{revision}
```

lowercased, runs of non-alphanumerics collapsed to `_` — e.g.
`chunks__tei__qwen_qwen3-embedding-0_6b__1024__a1b2c3d4e5f6`. This amends ADR 0002's naming rule by
one component: two pinned revisions of one model produce vectors that are **not comparable**, so a
revision is part of what the name must distinguish. The chunker version stays out of the name,
because a chunker bump is an in-place rebuild of the same collection.

The name is also how the deployment answers "what is being served": parsing the alias target gives
the identity, revision and dimensions retrieval is really using. No second table records that.

### One read alias, `chunks_current`

Retrieval names the alias and never a physical collection — one Qdrant lookup, resolved server-side,
so a flip is picked up by the very next query with no cache to invalidate. Writes name their target
explicitly: ingestion writes to the **alias's target** (which may be a collection built by an earlier
run), and a rebuilding run writes to its own target collection, which is by construction not the one
being read.

`migrate`'s `ensure-collection` creates the configured collection and its payload indexes if absent,
**and creates `chunks_current` if no alias exists at all**. A fresh deployment and a restored one are
the same case: an empty collection, an alias pointing at it, and points appearing as the run fills
it in. `/readyz` requires the alias to resolve, because without it retrieval cannot run at all.

### Detection is a Postgres query, not a collection scan

The document row already carries the generation it currently describes, so staleness is one
predicate:

```sql
select id from documents
where status = 'ready'
  and (embedding_provider    is distinct from :provider
    or embedding_model       is distinct from :model
    or embedding_dims        is distinct from :dims
    or embedding_revision    is distinct from :revision
    or chunker_version       is distinct from :chunker_version
    or chunk_config_hash     is distinct from :config_hash)
order by id;
```

Qdrant is never asked. It is derived and empty after a restore, so it cannot say what *should* exist —
the one case this ticket also has to serve. That case is `--all`, the only other detector: every
`ready` document, regardless of the generation its row claims. `--dry-run` prints whichever set would
be enqueued.

### A run is a row, and its membership is frozen when it opens

`reindex_runs` records the two collection names, the two chunker versions, the state (`building →
verifying → switched`, or `failed`) and the failure code — nothing that can be read off a name or
counted from a row. Provider, model, dimensions and revision are parsed from the collection names,
which is what those names are for; `source_chunker_version` is kept because a rollback has to know
whether the run re-chunked. `reindex_run_documents` records the intent, one row per document,
`pending | done | failed`. Progress is a `count(*) filter (…)` over membership, never a counter that
can drift.

Freezing matters for `--resume`: a resumed run re-enqueues only its own unfinished documents, and
"how many were meant" survives a restart. A document deleted mid-run cascades out of membership and
its job becomes a no-op, which is the behaviour the ingestion worker already has; where its points go
is [below](#a-shadow-run-owns-its-target-collection).

### The rebuild is queue work, driven by the CLI

`app.cli reindex` opens the run, then defers one `reindex_document` job per member onto the existing
procrastinate queue — no second queue, no new service. Each job:

1. reads the document's current-generation chunk rows from Postgres (never the PDF, never the
   parser: chunk text is a verified slice of canonical markdown, ADR 0011);
2. re-chunks first when the target chunker version differs, from the **persisted parse artifact** —
   `document_content.parsed_json`, the parser's own tree, stored so a re-chunk needs neither the PDF
   nor a layout pass;
3. embeds the prefixed display text and upserts points. A **shadow** run writes them active — nobody
   is reading that collection — while an **in-place** run stages them `is_active: false` and then
   activates, because that collection is being served and must never show half a document;
4. verifies by an **exact** filtered `count` against the target generation's rows in `chunks` — never
   `documents.chunks_total`, which still counts the generation being replaced;
5. and only then writes the target generation onto the document's and chunks' embedding columns and
   moves `chunker_version` and `chunks_total` in the same transaction, so a document row never names
   a generation whose points are not all active;
6. and, for an **in-place** run, deactivates the superseded generation's points. The membership row
   is marked `done` only after that update lands, which is what stops the transient overlap from
   outliving a crash: a resumed job retires the superseded generation before it activates, and a run
   cannot reach `verifying` with a duplicate live.

Being ordinary queue jobs is what makes the run resumable: a crash loses at most one document, and
`reindex --resume <run-id>` re-enqueues that one. Embed calls reuse ingestion's batch size instead of
adding a second knob for the same TEI limit, and document concurrency is the worker's pool, which is
why the runbook says `WORKER_CONCURRENCY=2` is what makes a rebuild practical on 16 GB.

### A shadow run owns its target collection

The target may already exist — an aborted earlier run to the same identity, or a collection someone
created by hand. Nothing in a name says whose points those are, and the flip gate can only count the
documents it knows about, so a shadow run makes its target true before writing:

- it asserts the collection's dense vector configuration matches the target identity (size, distance)
  and refuses with a typed message otherwise, because a hand-made collection is the one way a wrong
  shape can carry the right name;
- it deletes, by `document_id` filter, every point whose document is not in its frozen membership —
  the same purge a document deletion performs, and what makes a resumed or restarted run land in the
  same place instead of inheriting a predecessor's orphans.

A document deleted while a run is open is therefore purged from **both** the serving collection and
the open run's target: membership cascades out, its job no-ops, and no point of it survives to be
served after the flip. Deletion after the flip purges the collection then being served — one rule,
applied to whatever is served and to whatever is building.

### Cutover

The run moves to `verifying` when every membership row is `done`, and only then:

1. **Shadow build:** an exact filtered count of the run's documents and active points in the target
   collection must equal the sum of their chunk counts — the same check activation uses, promoted to
   the run. Then one `POST /collections/aliases` batch with `delete_alias{chunks_current}` and
   `create_alias{target_collection, chunks_current}`, then `state = 'switched'`. A query in flight
   finishes against whichever collection it resolved; nothing is drained, because nothing can be.
2. **In-place rebuild:** there is nothing to flip. The run is `switched` when the last document's
   superseded generation has been deactivated and a filtered count of it reaches zero. This is
   per-document publication, not a corpus-wide moment.

**A run is all-or-nothing at the flip.** One document that exhausts its retries fails the run
(`state = 'failed'`, `failure_code = 'document_failed'`, the failing membership row carries the
document's error code) and the alias does not move. A half-migrated library is the state that
produces wrong answers. The escape hatches already exist: the document's own retry, or deleting it.

### Ingestion is paused exactly while the serving collection is not the configured one

Because the configured identity is also what ingestion embeds with, a deployment whose alias points at
a collection built from another identity can only *produce* vectors its read path cannot see. That is
the one state this design refuses to enter: the worker re-defers ingestion jobs (60 s, not failing
them) while `parse(alias_target).identity != configured identity`, so uploads stay `queued` and their
status polls keep answering `Retry-After` — a state the UI already handles. One `index_behind_config`
warning is logged per boot, and `reindex status` reports the pause and the run that would end it.

The pause is a scheduler condition and never a document state, so a paused job re-defers without
claiming and the document keeps `queued`. A row left `ingesting` by the restart that changed the
configuration is reset to `queued` by the worker at startup: with exactly one worker instance
([ADR 0012](./0012-one-compose-stack-with-a-caddy-overlay.md)) any such row is provably orphaned, and
without the reset it would age into the maintenance sweep's `job_lost` failure and need a manual
retry — a stall turning into a fault for no reason.

Changing `.env` therefore never silently half-migrates: the api keeps answering from the old
collection, ingestion stalls, and the warning names the command. Nothing fails closed at boot, which
would take the whole site down for the length of a rebuild to prevent a warning.

### Cost, and what is visible

Every embedding call the run makes is a `model_calls` row with `scope = 'product'`,
`subject_kind = 'ingestion'` and the document's owner — the same shape ingestion writes, so a hosted
embedding identity makes a rebuild visible per account instead of appearing as unexplained spend. A
run is **never admission-checked**: a budget refusal mid-run would leave the index half-built and the
alias unmoved, so the runbook warns about cost instead and the admission check keeps doing the one job
it was designed for.

Operator surface is the CLI (`reindex status` reads the run row and its membership) plus one
structured log line per state transition. `/readyz` stays a boolean; a migration in flight makes the
deployment fully ready, because it is fully serving. Nothing is added to the admin page, and nothing
here belongs to the observability ticket.

## Considered Options

- **Versioned collection names resolved by the app, no alias** — one less Qdrant object, and the
  cutover becomes a row the app reads instead of an atomic Qdrant operation every reader must agree on.
- **Named-vector shadow inside the live collection** — free rollback, no copy, ids and payloads
  untouched; only works when dimensions and distance match, still rebuilds the per-tenant graph, and
  breaks the one-collection-per-identity rule the payload schema and chunk provenance rely on.
- **Keep ingesting during a rebuild and let new uploads go uncitable until cutover** — no stalled
  queue, at the cost of documents that read `ready` while answers cannot cite them, which presents as a
  retrieval bug.
- **Dual-write old and new collections** — removes the stall entirely; needs a second embedding model
  served concurrently, a migration-only code path and a second TEI container.
- **Flip once a threshold of documents is rebuilt** — one bad PDF cannot hold a migration hostage,
  and the library is left silently split across two models with a threshold nobody has data for.
- **Delete the superseded collection at the flip** — one copy on disk, no rollback: a retrieval
  regression discovered days later becomes a full rebuild under an embedder the container no longer
  serves.
- **Fail closed at boot on an identity mismatch** — impossible to run half-migrated; the whole site is
  down for the rebuild, and the reindex has to be run with `--no-deps` before the stack will start.
- **Re-parse the PDF to re-chunk** — no new artifact; uploads can drift, and the layout pass is the
  1–2 GB memory spike the floor is built around, so a chunker experiment becomes the heaviest operation
  the deployment has.
- **Re-chunk from canonical markdown with a markdown splitter** — cheapest; the same `chunker_version`
  would mean two different splitters depending on which path ran, which is the determinism the version
  exists to guarantee.
- **Detect staleness by scrolling Qdrant payloads** — inverts the dependency on a store that is empty
  after a restore.
- **Recompute the stale set on every resume** — no membership table; the run loses its denominator and
  a mid-run deletion silently shrinks the target.
- **Admission-check each document job** — consistent with the budget promise, and a large library can
  never be migrated while the month's ceiling stands.
- **Refuse to build into a target collection that already exists** — no reconciliation path at all,
  and an aborted run leaves a collection an operator must delete by hand before the next attempt.
- **Purge a deleted document from the serving collection only** — one write instead of two, and its
  points come back as citations the moment the alias moves.
- **Give a paused ingestion a status of its own** — a fifth document state every reader and every
  status poll would have to know, for a condition that belongs to the worker's scheduler.
- **Surface migration state in `/readyz` or the admin page** — a status document where a boolean gate
  is defined, or a tenth UI surface for an operator procedure.

## Consequences

- **An embedding change is a rebuild, and a rebuild is a copy.** Peak disk during a migration is two
  collections plus their indexes, on a box whose floor is 40 GB; `reindex retire` is the step that
  gives it back, and the runbook's disk guidance names it.
- **Rollback is defined for shadow runs only, and only while the superseded collection exists.**
  `reindex rollback <run>` repoints the alias and rewrites the generation columns back to the source
  generation the run recorded — `source_collection` names its identity, `source_chunker_version` its
  generation. An in-place (chunker) run has no rollback: its old generation is retired document
  by document, and the recovery is to fix the splitter and run again — cheap, because canonical
  markdown and `parsed_json` are both persisted.
- **A crash mid-run is resumable, not silent.** Generation columns are updated per document as it
  completes, so a crashed shadow run looks "done" to a fresh staleness query; the one-open-run
  constraint is what turns that into `reindex status` → `--resume`, and the CLI refuses to open a
  second run while one is open.
- **Ingestion stalls during an embedding migration by design**, and a document can sit `queued` for
  the length of the rebuild. On the 8 GB floor a large rebuild is slow; the runbook says so instead of
  pretending the box is bigger.
- **`document_content` grows.** The parse artifact is typically several times the canonical markdown,
  stored without page images (figures are caption-only by [the chunking decision](https://github.com/mobley-trent/genweaver/issues/4)),
  and it is the price of a re-chunk that needs no PDF and no layout pass.
- **A superseded chunker generation lives 30 days past its replacement, then goes.** The sweep deletes
  its chunk rows first and their Qdrant points second, by the same `document_id + chunker_version`
  filter, because a point without a row cannot be rendered while a row without a point is only
  unreachable. Carried chunks from a conversation older than that drop, which is the behaviour
  [ADR 0010](./0010-memory-is-a-small-window-over-a-pinned-carry-forward.md) already states, and
  citations stay legible because they are snapshots. Thirty days is provisional — it matches session
  retention and moves by a measurement of the chunk table, not by taste — and it is why an embedding
  migration does not need a retention rule of its own: it rewrites rows in place rather than adding a
  generation.
- **Two tables enter the schema** — `reindex_runs` and `reindex_run_documents` — and
  `document_content` gains `parsed_json`. `docs/schema/0001-initial.sql` carries them.
- **A chunk's embedding columns describe the collection its vector was written to**, so during a run
  a rebuilt document's rows name the target collection while the alias still serves the source. That
  is truthful — [ADR 0011's amendment](./0011-postgres-is-the-source-of-truth-and-history-is-a-snapshot.md)
  defines "current generation" per document for exactly this window — and the run row is what explains
  the gap; a guard reverting the rows does not exist, because the rows are the evidence.
- **The restore path and the migration path are now literally the same command**, so the disaster
  path is exercised by ordinary operation: restore, `reindex --all`, and the alias it creates is what
  `/readyz` checks.
- **Two glossary terms entered the language** — **Serving index** and **Reindex run** — and
  **Embedding identity** now names the pinned revision, because two revisions of one model are two
  vector spaces.
