# Postgres as the ingestion queue, with chunks activated only when a document finishes

**Status:** accepted

Ingestion runs as a **procrastinate** worker, a queue that keeps its state in the Postgres the application already needs, so an upload's document row and its job commit in one transaction and no Redis enters `docker compose`. The ticket this came from assumed arq, which is now in maintenance-only mode; taskiq and Celery would each add a broker service to serve one producer and one consumer. The second half of the decision is that a document's vectors are written **staged** (`is_active: false`) and flipped active in a single filter-based update only once the last chunk lands, so a half-ingested document can never answer a question.

## Considered Options

- **arq, taskiq or Celery on Redis** — a broker service for a single-node stack; arq is additionally unmaintained.
- **A hand-rolled `SELECT … FOR UPDATE SKIP LOCKED` job table** — we would own retry, backoff and stuck-job recovery, the parts most likely to be wrong.
- **Incremental visibility** (chunks queryable as they land) — answers could quote half a document.
- **Writing all vectors at the end in one call** — memory grows with document size, and one big all-or-nothing write.

## Consequences

- Postgres is the only progress source; no client and no API request reads queue internals or Qdrant point counts.
- The Qdrant payload carries `is_active`, and **every** retrieval filter must include it — a missing filter silently serves failed documents' chunks.
- Qdrant applies a filter-based payload update point by point across segments, with no atomicity guarantee, so activation is **verified by a filtered count** before the document is published, and retrieval additionally gates on the document's `ready` status in Postgres.
- Stalled-job recovery is **not built in**: the maintenance sweep implements it, and its threshold is heartbeat-based, so it must be set above the worst-case blocking parse rather than tied to `job_timeout`.
- procrastinate owns its tables and migrations; our own migrations must not touch them.
- The queue is reached through one small wrapper module, so replacing the library (it is soliciting maintainers) stays a contained change.
- A crashed worker, a wiped queue or a botched deploy degrades to "document failed, user retries" rather than a silently missing document, because a periodic maintenance sweep reconciles staged garbage and lost jobs.
