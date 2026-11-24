# Operator runbook

How to run, back up, upgrade and repair a genweaver deployment. The decision behind the shape is
[ADR 0012](../adr/0012-one-compose-stack-with-a-caddy-overlay.md); the files it describes are
`compose.yaml`, `compose.https.yaml`, `compose.dev.yaml` and `deploy/Caddyfile`.

> **Status.** genweaver is at the specification stage: the compose files are the deployment contract,
> and the CLI verbs below (`create-admin`, `invite`, `reindex`, …) are what the specification requires
> them to be. Nothing here is runnable until the application exists.

## What is running

| Container | Job | Notes |
| --- | --- | --- |
| `postgres` | Source of truth, ingestion queue, sessions, ledger | Not published. `pg_isready` healthcheck |
| `qdrant` | One tenant-partitioned collection per embedding identity | Not published; API key required |
| `tei` | Embeddings, `Qwen/Qwen3-Embedding-0.6B` at a pinned revision | Not published; ~2.4 GB resident |
| `api` | REST + SSE at `/api/v1`, in-process verifier | `127.0.0.1:8000`; `/healthz`, `/readyz` |
| `worker` | Ingestion, reindex, hourly maintenance sweep | Exactly one instance |
| `migrate` | Migrations, queue schema, collection creation | One-shot; exits 0 |
| `caddy` | TLS termination and one site | Only with `compose.https.yaml` |

**Floor: 4 vCPU / 8 GB RAM / 40 GB SSD.** Recommended for real use: 16 GB, with
`WORKER_CONCURRENCY=2`. Under 8 GB the parse spike and a live answer compete; see
[When the floor is not enough](#when-the-floor-is-not-enough).

## First run

```bash
git clone <repo> genweaver && cd genweaver
cp .env.example .env && chmod 600 .env
```

Fill `.env`:

1. `POSTGRES_PASSWORD`, `QDRANT_API_KEY` — `openssl rand -base64 32` each.
2. `CHAT_API_KEY` — a DeepSeek key. It never leaves the server.
3. `EMBEDDING_REVISION`, `VERIFIER_REVISION` — commit shas, not branch names:
   ```bash
   curl -fsSL https://huggingface.co/api/models/Qwen/Qwen3-Embedding-0.6B \
     | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])'
   curl -fsSL https://huggingface.co/api/models/vectara/hallucination_evaluation_model \
     | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])'
   ```

Then:

```bash
mkdir -p data/uploads data/backups
docker compose up -d
# give the uploaded directory to the app's uid once; no host sudo needed
docker compose run --rm --user root api chown -R 10001:10001 /data/uploads

docker compose ps                     # migrate should be Exited (0); api healthy
curl -fsS localhost:8000/healthz      # liveness
curl -fsS localhost:8000/readyz       # Postgres + Qdrant + TEI + warmed verifier
```

The **first boot downloads roughly 3 GB of models** (TEI weights and HHEM) before `/readyz` turns
green; the api's healthcheck allows 180 s and a slower cold start is expected, not a fault. Watch it
with `docker compose logs -f api tei`.

Create the first admin — it refuses to run once any admin exists, and there is no seeded credential:

```bash
docker compose exec api python -m app.cli create-admin    # prompts for email and password
open http://localhost:8000
```

### Public deployment

Requirements: a DNS `A` record for `DOMAIN` pointing at the host, ports 80 and 443 reachable, and
`DOMAIN` + `ACME_EMAIL` in `.env`.

```bash
docker compose -f compose.yaml -f compose.https.yaml up -d
docker compose logs -f caddy        # certificate obtained, then "serving"
```

`APP_ORIGIN` becomes `https://${DOMAIN}` automatically; nothing else changes. `http://localhost:8000`
stays published on loopback for direct inspection and never reaches the internet.

## Environment reference

`.env` is interpolated by Compose and read by nothing else. Internal URLs (`DATABASE_URL`,
`QDRANT_URL`, `EMBEDDING_BASE_URL`) are assembled in `compose.yaml`; do not set them in `.env`.

| Variable | Required | Default | Meaning |
| --- | --- | --- | --- |
| `POSTGRES_PASSWORD` | yes | — | Password for the `genweaver` database role |
| `QDRANT_API_KEY` | yes | — | Qdrant API key (internal network only) |
| `CHAT_API_KEY` | yes | — | DeepSeek key; product and eval traffic |
| `EMBEDDING_REVISION` | yes | — | Pinned commit sha of the embedding model |
| `VERIFIER_REVISION` | yes | — | Pinned checkpoint revision of HHEM |
| `APP_ORIGIN` | no | `http://localhost:8000` | Browser origin; CSRF check and links; overlay sets it from `DOMAIN` |
| `DOMAIN` | overlay only | — | Hostname Caddy issues a certificate for |
| `ACME_EMAIL` | overlay only | — | ACME account address for expiry notices |
| `CHAT_PROVIDER` / `CHAT_MODEL` | no | `deepseek` / `deepseek-flash` | Chat seam selection, must be in the model registry |
| `CHAT_BASE_URL` | no | `https://api.deepseek.com` | No `/v1` suffix |
| `CHAT_THINKING` / `CHAT_TEMPERATURE` | no | `off` / `0.2` | Recorded per answer |
| `EMBEDDING_PROVIDER` / `EMBEDDING_MODEL` / `EMBEDDING_DIMS` | no | `tei` / `Qwen/Qwen3-Embedding-0.6B` / `1024` | Embedding identity; decides the collection name |
| `VERIFIER_MODEL` | no | `hhem-2.1-open` | Registry name; cannot point at a chat provider |
| `BUDGET_ACCOUNT_MONTHLY_USD` | no | `5.00` | Hard per-Account monthly budget |
| `BUDGET_ACCOUNT_DAILY_SOFT_USD` | no | `1.00` | Soft daily warning threshold |
| `BUDGET_DEPLOYMENT_MONTHLY_USD` | no | `50.00` | Hard deployment-wide ceiling |
| `WORKER_CONCURRENCY` | no | `1` | Concurrent ingestions; 2 only on 16 GB |
| `UPLOAD_MAX_BYTES` | no | `52428800` | App-side upload ceiling (50 MiB, ADR 0009); Caddy's edge cap is 55 MB |
| `API_PORT` | no | `8000` | Loopback port published by `api` |
| `LOG_LEVEL` | no | `INFO` | `DEBUG` for a debugging session only |

A missing required value **fails `docker compose up`**, by design: an empty password or an unpinned
model revision is a deployment that would silently record the wrong provenance.

## Day-2 checks

```bash
docker compose ps                       # every service Up; api (healthy)
curl -fsS localhost:8000/readyz         # the readiness oracle
docker compose logs --since 1h api worker
docker system df                        # disk
```

Logs are structured JSON on stdout, rotated by Docker at 10 MB × 3 per container. Readiness is
`/readyz` (Postgres, Qdrant, TEI, warmed verifier); liveness is `/healthz` (the process answers). A
chat-provider outage leaves `/readyz` green and makes answers fail visibly — that is intended.

## Accounts and invites

```bash
docker compose exec api python -m app.cli create-admin
docker compose exec api python -m app.cli invite create --email person@example.com --role member
docker compose exec api python -m app.cli invite revoke <invite-id>
docker compose exec api python -m app.cli sessions terminate --email person@example.com
docker compose exec api python -m app.cli password-reset --email person@example.com
```

`invite create` prints the token and its redemption URL **once**; the database keeps only a hash. There
is no mail delivery: hand the URL over yourself. `sessions terminate` is the answer to a lost device
or a compromised password, and takes effect on the next request. Deactivating or deleting an Account
is [its own decision](https://github.com/mobley-trent/genweaver/issues/19); this runbook does not
improvise it.

## Backup and restore

**Backed up:** the database and the original PDFs. **Not backed up:** Qdrant (rebuilt by reindexing),
model caches (re-downloaded), Caddy certificates (re-issued).

```bash
ts=$(date -u +%Y%m%dT%H%M%SZ)
docker compose exec -T postgres pg_dump -U genweaver -Fc genweaver \
  > data/backups/genweaver-$ts.dump
tar -C data -czf data/backups/uploads-$ts.tgz uploads
```

Run that nightly at 03:00 UTC from cron and **before every upgrade**; keep 14 days:

```cron
0 3 * * * cd /srv/genweaver && ts=$(date -u +%Y%m%dT%H%M%SZ) && \
  docker compose exec -T postgres pg_dump -U genweaver -Fc genweaver > data/backups/genweaver-$ts.dump && \
  tar -C data -czf data/backups/uploads-$ts.tgz uploads && \
  find data/backups -type f -mtime +14 -delete
```

**Promise: ≤ 24 hours of loss.** An answer given after the last dump is gone. Nothing here is
point-in-time recovery; the ledger, conversations and documents are restored to the dump's instant.

### Restore

```bash
ts=20261124T030000Z            # the dump to restore
docker compose stop api worker
docker compose exec -T postgres dropdb   -U genweaver --if-exists genweaver
docker compose exec -T postgres createdb -U genweaver genweaver
docker compose exec -T postgres pg_restore -U genweaver -d genweaver --clean --if-exists \
  < data/backups/genweaver-$ts.dump
tar -C data -xzf data/backups/uploads-$ts.tgz

docker compose up -d           # migrate verifies the schema and ensures the collection
docker compose run --rm api python -m app.cli reindex --all
curl -fsS localhost:8000/readyz
```

The last step is not optional: **Qdrant is empty after a restore**, so until the reindex runs the
library is intact and every question answers `insufficient_support`. The reindex re-embeds chunk text
from Postgres and needs no PDFs. Its exact name and flags belong to
[Decide the reindexing and embedding-model migration strategy](https://github.com/mobley-trent/genweaver/issues/18);
the restore path requires that it can rebuild every vector from Postgres alone.

Rehearse the restore once on a scratch host before you need it: a backup nobody has restored is a
hypothesis.

## Upgrade

```bash
docker compose exec -T postgres pg_dump -U genweaver -Fc genweaver > data/backups/pre-upgrade-$(date -u +%Y%m%dT%H%M%SZ).dump
git pull
docker compose pull           # base images (postgres, qdrant, tei, caddy)
docker compose build          # api and worker targets
docker compose up -d          # migrate runs first; api and worker wait for it
docker compose ps && curl -fsS localhost:8000/readyz
```

If `migrate` exits non-zero, the api and worker do not start — that is the fail-closed behaviour, not
a hung deploy. Read its output with `docker compose run --rm migrate` and fix forward; restore the
pre-upgrade dump if the migration itself was wrong.

**Restarts drop in-flight answers.** There is no drain and no resumable stream, so upgrade when nobody
is mid-question. A crashed answer leaves its usage rows and no Answer row; the person asks again.

### Changing the model or the embedding identity

Chat model changes are a `.env` change and a restart (`CHAT_MODEL=…`, `docker compose up -d api`);
provenance records the new model from the next answer on. An **embedding** change is not: the
collection name is the embedding identity, so a new model means a new collection and a reindex of every
document — that procedure, and whether the old generation is served meanwhile, is
[Decide the reindexing and embedding-model migration strategy](https://github.com/mobley-trent/genweaver/issues/18).
Raising `WORKER_CONCURRENCY` while a reindex runs is how a 16 GB host gets it done without stalling
uploads; on 8 GB, expect ingestion to queue.

A **Postgres major** upgrade (18 → 19) is dump-and-restore, not a tag change: the image's data layout
is version-specific (`/var/lib/postgresql/18/docker`), and an in-place upgrade needs `pg_upgrade` on
the same volume. Take a dump, start the new major on an empty volume, restore, reindex.

## Budgets, keys and prices

```bash
docker compose logs api | grep budget            # refusals and soft-threshold warnings
```

- Per-Account monthly hard budget ($5), per-Account daily soft threshold ($1), deployment monthly hard
  ceiling ($50) are `.env` values; changing one needs `docker compose up -d api`.
- A `budget_exhausted` refusal resets when the calendar month rolls (UTC). An admin is exempt from
  Account budgets but not from the deployment ceiling.
- Rotate the chat key by editing `CHAT_API_KEY` and `docker compose up -d api`. No restart of any other
  service is needed, and no other file holds it.
- **Rate card refreshes** are a commit to `config/pricing.toml` plus a rebuild: DeepSeek changes rates
  and peak policy without asking. Rows written after the change keep the old `price_version`, which is
  how an unrefreshed card is visible rather than silent.

## When the floor is not enough

| Symptom | Look at | Do |
| --- | --- | --- |
| `api` killed or OOM during a question | `docker compose ps`, `dmesg` | Raise RAM: TEI (~2.4 GB) + api (~1.2 GB) are resident, not cache |
| `tei` restarts while ingesting | `docker compose logs tei` | Same: the parse spike plus TEI exceeds the box |
| Ingestion stuck `queued` | `docker compose logs worker` | Worker not running, or busy with another document (`WORKER_CONCURRENCY=1`) |
| Ingestions crawl, answers fine | `docker stats` | 2 vCPU is not enough for Docling; 4 is the floor |
| Disk full | `docker system df`, `du -sh data/*` | Prune old images, check backup retention, then uploads |

On 8 GB: keep one worker and one ingestion, avoid reindexing while people are asking. On 16 GB: set
`WORKER_CONCURRENCY=2` and reindex alongside serving.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `docker compose up` refuses with `set … in .env` | Required value empty | Fill `.env`; that is fail-closed, not a bug |
| `api` unhealthy, `/readyz` 503 | Postgres/Qdrant/TEI unreachable, or verifier not warm | `docker compose logs api tei`; first boot can take minutes |
| `/healthz` 200 but `/readyz` 503 | A dependency, not the process | Check `docker compose ps` for restarting `qdrant`/`tei` |
| Caddy returns 502 | api not healthy, or cert issued but upstream down | `docker compose ps api`; `curl localhost:8000/healthz` |
| Caddy cannot get a certificate | DNS not pointing here, port 80/443 closed, wrong `ACME_EMAIL` | `docker compose logs caddy`; fix DNS/firewall, restart caddy |
| Signed out immediately on a remote host | Serving plain HTTP, so no `Secure` cookie | Use `compose.https.yaml` |
| Signed out on localhost in one browser | That browser refuses `Secure` cookies on localhost | Use Chrome or Firefox locally, or the HTTPS overlay |
| Every answer `insufficient_support` on a library that looks fine | Qdrant empty (fresh restore) or reindex not run | `python -m app.cli reindex --all` |
| `deployment_budget_exhausted` for everyone | Deployment ceiling reached | Raise `BUDGET_DEPLOYMENT_MONTHLY_USD` or wait for the month |
| Login works, then 403 on writes | `APP_ORIGIN` disagrees with the browser origin | Set `APP_ORIGIN` to the exact origin, `docker compose up -d api` |
| A document sits `failed` with `job_lost` | Worker died mid-ingestion; the sweep noticed | `POST /documents/{id}/retry`, or delete and re-upload |

## Security notes

- `.env` is `chmod 600` and gitignored; it is the only place secrets live. No secret is baked into an
  image, echoed into a log, or stored in the database.
- Nothing but Caddy is reachable from the internet: PostgreSQL, Qdrant and TEI have no published
  ports, and the api's publish is loopback.
- Caddy state (`caddy_data`) holds the ACME account key and certificate; it is re-issuable, so it is
  not in the backup set — but losing it means a fresh issuance, not a broken site.
- There is no SMTP by design: invite emails are labels, not verified identities, and password resets
  are admin-issued links handed over out of band. Nothing in the product may imply a verified address.
- No metrics or tracing endpoint is exposed; the loopback-bound `/readyz` and container logs are the
  whole surface until the observability decision lands.
