# 0012. Ship one Compose stack, put TLS in an overlay, and back up only Postgres and the originals

- Status: Accepted
- Date: 2026-11-24

## Context

The project's promise is that a stranger can clone it, set env, run `docker compose up` and ask a
question about a PDF. Twelve earlier decisions determined what has to be running for that to be true,
and none of them said how it stands up.

Six processes fall out of those decisions and no others. **postgres** is the source of truth and the
ingestion queue ([ADR 0001](./0001-postgres-ingestion-queue-and-staged-chunks.md),
[ADR 0011](./0011-postgres-is-the-source-of-truth-and-history-is-a-snapshot.md)). **qdrant** holds
vectors and BM25 payload text ([ADR 0002](./0002-tenant-partitioned-hybrid-retrieval-without-sparse-vectors.md)).
**tei** serves embeddings, because DeepSeek has none
([ADR 0007](./0007-own-the-model-seams-and-fail-closed.md)). **api** serves REST and SSE and runs the
local verifier ([ADR 0003](./0003-verified-citations-with-a-local-verifier.md),
[ADR 0009](./0009-serve-rest-with-sse-over-fetch.md)). **worker** ingests and sweeps
([ADR 0001](./0001-postgres-ingestion-queue-and-staged-chunks.md)). **migrate** exists only because
three stores need schema before two long-running processes may start.

Three facts decide most of the shape.

**TLS is a deployment feature here, not a nicety.** The session cookie is `__Host-` with `Secure`
([ADR 0005](./0005-accounts-are-invite-only-and-auth-runs-in-the-app.md)). Browsers treat
`http://localhost` as a secure context and accept such a cookie there; a remote host serving plain
HTTP cannot hold a session at all. So the local path and the public path genuinely differ, and the
difference is one proxy.

**Verification is local and cheap, and readiness must mean "the verifier is warm."** ADR 0009 already
requires `/readyz` to include a warmed verifier and forbids a chat-provider outage from making the app
unready. That is only implementable if the verifier is in the process being probed.

**The two stores are not symmetric.** Everything in Qdrant is derivable — a chunk's text is a byte
slice of canonical markdown in Postgres ([ADR 0011](./0011-postgres-is-the-source-of-truth-and-history-is-a-snapshot.md)),
its vector is a deterministic function of that text and the embedding identity, and its point id is
`uuid5`. The canonical markdown and the uploaded PDFs are derivable from nothing. A backup policy that
treats three stores alike spends effort on the one that regenerates itself.

## Decision

### Services, images and ports

| Service | Image | Publishes | Notes |
| --- | --- | --- | --- |
| `postgres` | `postgres:18.7-trixie` | — | Volume at `/var/lib/postgresql` (18 moved PGDATA to `18/docker`); `shared_buffers=256MB`, `max_connections=50`; `pg_isready` healthcheck |
| `qdrant` | `qdrant/qdrant:v1.20.2` | — | `QDRANT__SERVICE__API_KEY` from `.env`; telemetry off; no healthcheck (see below) |
| `tei` | `ghcr.io/huggingface/text-embeddings-inference:cpu-1.9` | — | `--model-id` + `--revision` from `.env`; cache volume at `/data`; serves the OpenAI-shaped `/v1/embeddings` the adapter expects |
| `migrate` | build target `api` | — | Runs once and exits |
| `api` | build target `api` | `127.0.0.1:8000` | Uvicorn with `--proxy-headers`; healthcheck on `/readyz` |
| `worker` | build target `worker` | — | `procrastinate worker`, concurrency `${WORKER_CONCURRENCY:-1}` |
| `caddy` | `caddy:2.10-alpine` | `80`, `443`, `443/udp` | Only in `compose.https.yaml`; automatic ACME TLS |

Loopback publishes exist in both deployments: **the public path is always Caddy, and `127.0.0.1:8000`
exists so an operator can `curl` the app and read `/readyz` directly.** Qdrant, TEI and Postgres are
never published; a compose network is the boundary, and Qdrant carries an API key anyway because the
filter builder is a performance mechanism and not the tenancy boundary
([ADR 0002](./0002-tenant-partitioned-hybrid-retrieval-without-sparse-vectors.md)).

### One base file, one TLS overlay, one developer overlay

`compose.yaml` is the whole system and is what `docker compose up` finds. `compose.https.yaml` adds
Caddy and sets `APP_ORIGIN=https://${DOMAIN}` on the api, so the CSRF origin check and the cookie
scheme follow the deployment rather than a second hand-maintained value. `compose.dev.yaml` binds the
working tree, turns on `--reload`, and publishes the datastores to loopback for inspection.

The split is chosen so that **the local default needs no domain, no port 80 and no certificate**, and
the public deployment is one additional `-f` whose entire content is a proxy. A `DOMAIN=localhost`
trick that put Caddy in every run was rejected: it makes every local start bind port 80 and turns a
plain `docker compose up` into something that depends on a template variable.

### Migrations and first boot run as a one-shot service

`migrate` runs `alembic upgrade head`, `procrastinate --app=app.queue schema --apply` (the queue owns
its own tables and our chain must not touch them), then `python -m app.cli ensure-collection`, which
creates the collection and its payload indexes for the configured embedding identity if absent. It is
idempotent, so it is safe on every `up`. `api` and `worker` declare
`depends_on: {migrate: {condition: service_completed_successfully}}`.

A one-shot service rather than "the api migrates at boot" because two processes starting together
race on one migration chain, and a failed migration must stop the deployment instead of leaving an api
that Compose restarts forever against a schema that is not there. The migration is a step with one
exit code, visible in `docker compose ps -a`.

### The verifier runs inside the api

HHEM-2.1-Open loads and warms at api startup; `/readyz` returns 200 only once it has. This is what
ADR 0009's readiness clause assumes, it adds no HTTP transport behind the verifier seam, and the api
is the only process that verifies. It costs roughly 0.7–1.2 GB of resident memory in the api
container and makes a single api instance the deployment's shape.

**There are no compose healthchecks for Qdrant and TEI.** `/readyz` is the readiness oracle for
Postgres, Qdrant, TEI and the verifier together, because a healthcheck per dependency would answer
four questions the app already answers in one, and the app's answer is the one that matters (an
unavailable chat provider must *not* make it unready). `postgres` keeps a `pg_isready` healthcheck
because migrations must not start against a server that is not accepting connections.

### Volumes, and what a backup is

Named volumes `pgdata`, `qdrant`, `tei_cache`, `hf_home`; bind mounts `./data/uploads` (original PDFs)
and `./data/backups`. Application containers run as a fixed uid/gid 10001 baked into the image — not a
runtime `user:` override — so named volumes initialise with the right ownership; the runbook's first
run chowns `./data/uploads` once, from inside a container, so no host `sudo` is needed.

**Backed up:** `pg_dump -Fc` of the database and a tar of `./data/uploads`. Nightly at 03:00 UTC,
retained 14 days, plus one taken before every upgrade. **Not backed up:** Qdrant (rebuilt from
Postgres chunk text by reindexing), the model caches (re-downloaded), Caddy's certificate state
(re-issued).

The promised recovery point is **≤ 24 hours**, stated plainly rather than implied: an answer given
after the last dump is not recovered. The recovery *procedure* is the interesting half — restore the
dump and the uploads, then reindex, and Qdrant is rebuilt by re-embedding. That is deliberately the
same operation [Decide the reindexing and embedding-model migration strategy](https://github.com/mobley-trent/genweaver/issues/18)
must ship for model changes, so the disaster path is exercised by ordinary operation rather than
rotting until the day it is needed. 03:00 UTC is off-peak for DeepSeek, so a restore-and-reindex spends
nothing on chat.

### One worker, one api

The worker runs exactly one instance. It is what defers the hourly **maintenance sweep** from the
periodic registry, so a second worker would defer it twice, and it bounds ingestion to one parse at a
time, which is the deployment's memory spike. `WORKER_CONCURRENCY` is an environment knob (1 by
default, 2 only on the 16 GB profile) and there is deliberately no second queue: a separate reindex
queue would need prioritisation rules and a way to tune them that this product does not have.

The api runs exactly one instance too, and **a restart drops in-flight answers**. There is no drain,
no graceful handoff and no resumable stream; a process that dies mid-answer leaves the usage rows it
owes and, per ADR 0011, no Answer row at all. Deploys happen when nobody is mid-question.

### Proxy limits, headers and logging

Caddy caps a request body at 32 MB and the app keeps its own 25 MiB ceiling; the proxy cap exists so an
oversized upload is refused before FastAPI buffers it, and the app's ceiling exists so the direct-port
path behaves identically. SSE requires `flush_interval -1` (`proxy_buffering off` under nginx) — without
it every token arrives in one lump at the end. Uvicorn runs `--proxy-headers` and trusts the compose
network, because the login backoff is keyed per `(email, IP)` and would otherwise throttle every client
as one.

Everything logs structured JSON to stdout; Docker's `json-file` driver rotates at 10 MB × 3 per
container. **No metrics stack, no tracing, no `/metrics`.** `docker compose ps` and
`docker compose logs` are the operator's instruments. The map's observability fog graduates into its
own ticket rather than being pre-empted here.

### The floor

**4 vCPU / 8 GB RAM / 40 GB SSD.** 8 GB is the floor with one worker, not a comfortable number:
TEI's fp32 Qwen3-Embedding-0.6B is ~2.4 GB resident, the api with torch and HHEM is ~1.2 GB, an idle
worker with Docling is ~1.2 GB, Postgres and Qdrant together ~0.8 GB — about 6 GB steady — and a
Docling layout pass adds 1–2 GB on top. An ingestion overlapping a live answer is the configuration
that swaps. 16 GB is the recommended profile for a library people actually use, and is what makes
`WORKER_CONCURRENCY=2` sensible.

40 GB holds the application images (~7 GB), the model caches (~3 GB), the uploads, the WAL, and 14
dated dumps.

### What an operator is told

[`docs/operations/runbook.md`](../operations/runbook.md) is the operator document: first run, the
complete environment reference, account and invite procedures, backup and restore, upgrade, budget
and rate-card operations, and a troubleshooting table. The README carries only the three commands and
the floor, and points there.

## Considered Options

- **A separate verifier container** — api stays torch-free and model memory is isolated; costs a new
  HTTP transport behind a seam that has none, another service, and readiness split across two probes.
- **A lazy-loaded verifier** — smallest idle footprint, and `/readyz` would report ready before the
  verifier exists, which is the state ADR 0009 forbids and turns the first answer into the warm-up.
- **Caddy in the base file with `DOMAIN=localhost`** — one command everywhere; every local run binds
  port 80 and needs a generated site config, for a certificate it cannot issue.
- **No proxy in the repo** — smallest compose file, and the public path becomes prose about nginx that
  nobody ever ran.
- **The api migrates at boot** — one fewer service, and two containers race on one chain with a
  failure mode that keeps serving.
- **One image for api, worker and migrate** — one build to cache; 3–4 GB, with HHEM in the worker and
  Docling in the api, each unused.
- **CI-built images pulled from GHCR** — reproducible digests; `docker compose up` stops working on a
  fresh clone, and publishing becomes a precondition of the first boot.
- **One-shot snapshots of Qdrant in the backup set** — restores in minutes instead of re-embedding, at
  a second restore path and Qdrant's minor-version snapshot ceiling.
- **Everything in one bind-mounted `./data` tree** — visible and tar-able in one place; Postgres and
  Qdrant then write as uid 999 into host directories, the classic fresh-clone permission failure.
- **Host cron for the sweep, or a separate scheduler container** — one runs the sweep outside what
  `docker compose up` provides, the other adds a container to avoid a rule ("one worker") that is
  written down and bounded.
- **A drain window for restarts** — would need a drain endpoint, a readiness state that refuses
  admissions and a grace window, to protect a stream that a single-instance demo does not deserve.

## Consequences

- **`docker compose up` is the whole local product**: five long-running containers, one one-shot, no
  domain, no certificate, no registry, and a first boot that downloads ~3 GB of models before `/readyz`
  turns green. The api's `start_period` is 180 s and the runbook says so; a slow first boot is not a
  bug report.
- **The public deployment is one extra `-f` and two values** (`DOMAIN`, `ACME_EMAIL`). Caddy owns
  certificates and renewal; the runbook's TLS failure mode is DNS or a closed port, not a certbot cron.
- **The restore path depends on #18.** Restoring a backup without a reindex leaves an empty Qdrant and
  every question answering `insufficient_support` from an intact library — the most confusing possible
  state. The runbook does not offer a backup that cannot be restored, and the ticket that owns
  reindexing now owns half of disaster recovery.
- **The UI must be same-origin under the api** — no separate frontend service and no CORS. That is a
  constraint handed to [Decide the minimal UI scope](https://github.com/mobley-trent/genweaver/issues/16):
  a Vite or React build ships inside the api image and is served by it, and `APP_ORIGIN` is the only
  origin either cookie or CSRF logic knows.
- **Contracts handed to the API surface** (ADR 0009): `/healthz` must not touch dependencies and
  `/readyz` must include a warmed verifier and reachable Qdrant and TEI, but must not require a
  reachable chat provider; `APP_ORIGIN` drives absolute links and the Origin check; an oversized upload
  returns the typed error the app owns, not Caddy's bare 413.
- **The 8 GB floor is a floor, not a promise.** The arithmetic above is estimation from model sizes and
  framework footprints, not a measurement — nothing here has been run. It is recorded as a provisional
  number in the sense [ADR 0007](./0007-own-the-model-seams-and-fail-closed.md) uses, moved by a
  measurement (peak RSS per container under a real parse and a real answer) rather than by taste.
- **Eight unnamed knobs stay provisional**: `shared_buffers`, `max_connections`, the 32 MB proxy cap,
  the 25 MiB app ceiling, `WORKER_CONCURRENCY`, the 14-day retention, the 10 MB × 3 log rotation and
  the 180 s start period. Each has a default and a place in the runbook; none has a measurement.
- **Accepted losses, stated rather than implied**: a restart drops in-flight answers; the api is one
  process so one bad model load takes the site down; there is no draining, no horizontal scale, no
  metrics endpoint and no email delivery for invites.
- **Local browsers are a stated boundary**: `http://localhost` is a secure context for Chrome and
  Firefox, so the `__Host-` cookie works unchanged; any browser that refuses a `Secure` cookie there
  cannot hold a session, and the answer is the HTTPS overlay, not a weakened cookie.
- **No new terms entered the language.** *Deployment*, *operator* and *overlay* are the ordinary words
  they sound like; the glossary already carries the domain vocabulary this ticket configures
  (`Budget`, `Admission check`, `Maintenance sweep`, `Price version`).
- **Observability graduates.** The map's fog said tracing and metrics depend only on the deployment
  topology; the topology is now fixed, so that decision has its own ticket and this ADR deliberately
  ships no metrics surface to collide with it.
- Nothing about account deactivation, reindex strategy or UI scope is decided here; they remain their
  own tickets, and this ADR only fixes the topology they must fit into.

## Amendment — 2026-11-24: the upload ceiling

The numbers above drifted. [ADR 0009](0009-serve-rest-with-sse-over-fetch.md) set the app's upload knob at
50 MB (`MAX_UPLOAD_MB`), and this ADR recorded a 25 MiB app ceiling against a 32 MB proxy cap — so the
deployment advertised a limit the API never agreed to, and, worse, the proxy would refuse a body between
32 and 50 MB with an untyped 413 before the app could answer with its `payload_too_large` problem document.

Corrected in the checked-in stack: `UPLOAD_MAX_BYTES` is **52428800** (50 MiB) in `.env.example`, in
`compose.yaml`'s default and in the runbook's environment table; Caddy's edge cap is **55 MB**,
deliberately *above* the app ceiling so the app owns the refusal and the proxy only stops a body far past
it. The principle — the edge cap never binds before the application does — also appears in
[ADR 0013](0013-serve-a-server-rendered-ui-with-one-stream-client.md), because the browser path is where a
user meets it. Nothing else in this ADR changes, and the 50 MiB ceiling stays provisional until a real 50-page-plus PDF is measured.

## Amendment — 2026-11-24: `ensure-collection` creates the alias as well

The migration step above ends in `ensure-collection`, which
[ADR 0014](0014-reindex-builds-beside-the-serving-index.md) gave a second job: after creating the
configured collection and its payload indexes if absent, it creates the retrieval alias
`chunks_current` pointing at that collection **when no alias exists at all** — never repointing one
that does, because moving traffic is a reindex's cutover, and a migration step that could move it would
be a deploy that changes what everyone is reading.

That is what makes a fresh deployment and a restored one the same shape: an empty collection, an alias
pointing at it, and points appearing as the run fills it in. `docker compose up` after a restore is
therefore safe before the reindex runs, though every question is a miss until it finishes. `migrate`
still needs Qdrant reachable and its API key — collection creation already did — and still fails closed
on a store it cannot reach. An embedding identity that disagrees with the serving alias is **not** a
boot failure: ADR 0014 keeps that a serving state the worker holds, so the site keeps answering on the
old collection instead of refusing to start.
