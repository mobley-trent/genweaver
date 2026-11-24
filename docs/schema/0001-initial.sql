-- genweaver — initial schema
--
-- The specification for [Specify the Postgres data model](../../docs/adr/0011-postgres-is-the-source-of-truth-and-history-is-a-snapshot.md).
-- This file is the source for Alembic migration `0001_initial`. It parses under
-- libpg_query (Postgres's own grammar): 39 statements, 17 tables, 22 indexes.
-- It has never been executed against a server — syntax is not behaviour.
--
-- Requires PostgreSQL >= 18 for `uuidv7()`.
-- All timestamps are `timestamptz` and UTC. All money is integer micro-USD.
--
-- Procrastinate's own tables (`procrastinate_jobs`, …) are created by its
-- schema command and are deliberately absent here: one migration chain owns
-- our tables, the library owns its own.
--
-- Try to state a rule as a constraint rather than a comment. The rules that
-- remain comments are listed at the foot of this file.

-- ─── identity and access ────────────────────────────────────────────────

create table accounts (
  id            uuid primary key default uuidv7(),
  email         text not null,
  password_hash text not null,                  -- argon2id PHC string
  role          text not null default 'member' check (role in ('admin', 'member')),
  created_at    timestamptz not null default now()
);
-- Uniqueness is case-insensitive while the address is stored as written.
create unique index accounts_email_lower on accounts (lower(email));

create table sessions (
  id           uuid primary key default uuidv7(),
  account_id   uuid not null references accounts(id) on delete cascade,
  token_hash   bytea not null check (octet_length(token_hash) = 32),  -- sha256
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '12 hours',  -- absolute
  revoked_at   timestamptz
);
create unique index sessions_token on sessions (token_hash);
create index sessions_account_live on sessions (account_id) where revoked_at is null;
create index sessions_expiry on sessions (expires_at);

create table invites (
  id         uuid primary key default uuidv7(),
  token_hash bytea not null check (octet_length(token_hash) = 32),
  email      text not null,                    -- a binding label, never a verified identity
  role       text not null default 'member' check (role in ('admin', 'member')),
  created_by uuid references accounts(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '72 hours',
  used_at    timestamptz,
  used_by    uuid references accounts(id) on delete set null,
  revoked_at timestamptz
);
create unique index invites_token on invites (token_hash);
create index invites_recent on invites (created_at desc);

create table password_resets (
  id         uuid primary key default uuidv7(),
  account_id uuid not null references accounts(id) on delete cascade,
  token_hash bytea not null check (octet_length(token_hash) = 32),
  created_by uuid references accounts(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '24 hours',
  used_at    timestamptz,
  revoked_at timestamptz
);
create unique index password_resets_token on password_resets (token_hash);
-- Minting a second reset revokes the first: one live reset token per account.
create unique index password_resets_one_live on password_resets (account_id)
  where used_at is null and revoked_at is null;

-- A failure ledger, not a lock table: both the (email, ip) backoff and the
-- per-account lock are derived from these counts and timestamps.
create table login_attempts (
  email_lower       text not null,
  ip                inet not null,
  failures          smallint not null default 0 check (failures >= 0),
  window_started_at timestamptz not null default now(),
  last_failure_at   timestamptz not null default now(),
  primary key (email_lower, ip)
);
-- The primary key already serves "every failure row for this email".
create index login_attempts_recent on login_attempts (last_failure_at);

-- ─── documents, canonical text, chunks ──────────────────────────────────

create table documents (
  id                 uuid primary key default uuidv7(),
  owner_id           uuid not null references accounts(id) on delete cascade,
  original_filename  text not null,
  content_sha256     bytea not null check (octet_length(content_sha256) = 32),
  byte_size          bigint not null check (byte_size > 0),
  storage_path       text not null,
  status             text not null default 'queued' check (status in
                       ('queued', 'ingesting', 'ready', 'failed', 'cancelling', 'cancelled')),
  stage              text check (stage in ('parse', 'chunk', 'embed', 'activate')),
  pages_total        integer check (pages_total >= 0),
  pages_parsed       integer not null default 0 check (pages_parsed >= 0),
  chunks_total       integer check (chunks_total >= 0),   -- current indexing generation
  chunks_embedded    integer not null default 0 check (chunks_embedded >= 0),
  attempt            smallint not null default 0,
  error_code         text check (error_code in ('not_a_pdf', 'encrypted', 'parse_failed',
                       'chunk_failed', 'embed_failed', 'activation_failed',
                       'page_limit_exceeded', 'job_lost')),
  error_message      text,
  chunker_version    text,                      -- current indexing generation
  chunk_config_hash  text,
  embedding_provider text,                       -- current indexing generation
  embedding_model    text,
  embedding_dims     smallint,
  embedding_revision text,
  stage_started_at   timestamptz,
  activated_at       timestamptz,               -- when the activation count check passed
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  -- Content is identity: the same bytes re-uploaded in one Tenant is one document.
  unique (owner_id, content_sha256)
);
create index documents_owner_recent on documents (owner_id, created_at desc, id desc);
create index documents_owner_status on documents (owner_id, status);

-- The single serialization every offset and quote in the system refers to.
-- Its own table so the polled status row above stays narrow.
create table document_content (
  document_id        uuid primary key references documents(id) on delete cascade,
  content_hash       bytea not null check (octet_length(content_hash) = 32),
  canonical_markdown text not null,
  parser_name        text not null,
  parser_version     text not null,
  parsed_at          timestamptz not null default now()
);

create table chunks (
  -- uuid5(document_id, chunker_version, chunk_index): the Qdrant point id,
  -- so re-embedding the same chunk is an overwrite rather than a duplicate.
  id                 uuid primary key,
  document_id        uuid not null references documents(id) on delete cascade,
  chunker_version    text not null,
  chunk_config_hash  text not null,
  chunk_index        integer not null check (chunk_index >= 0),
  text               text not null,             -- display text; == canonical_markdown[char_start:char_end]
  context_prefix     text not null,             -- prepended before embedding, never shown
  kind               text not null check (kind in ('prose', 'table', 'figure_caption')),
  section_path       text[] not null default '{}',
  page_start         integer not null check (page_start >= 1),
  page_end           integer not null check (page_end >= page_start),
  page_labels        text[],
  char_start         integer not null check (char_start >= 0),
  char_end           integer not null check (char_end > char_start),
  token_count        integer not null check (token_count > 0),
  content_hash       bytea not null check (octet_length(content_hash) = 32),
  truncated_sentence boolean not null default false,
  embedding_provider text not null,
  embedding_model    text not null,
  embedding_dims     smallint not null,
  embedding_revision text,
  created_at         timestamptz not null default now(),
  -- Generations coexist: a chunker_version bump writes new ids beside the old ones.
  unique (document_id, chunker_version, chunk_index)
);
-- No index on document_id here: the unique constraint above already leads with
-- it, so the per-document count, the activation cross-check and the sweep have one.
-- (Chunks carry no owner_id: every read joins `documents`, which is where the
-- tenant check happens.)

-- ─── conversations and answers ─────────────────────────────────────────

create table conversations (
  id         uuid primary key default uuidv7(),
  owner_id   uuid not null references accounts(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index conversations_owner on conversations (owner_id, created_at desc, id desc);

-- An Answer is the turn: there is no messages table, and the person's question
-- is a column on the Answer. The row is written once, at completion.
create table answers (
  id                     uuid primary key,     -- allocated by the stream path; never defaulted
  conversation_id        uuid not null references conversations(id) on delete cascade,
  owner_id               uuid not null references accounts(id) on delete cascade,
  question               text not null,
  standalone_query       text,                  -- the rewrite's output, never shown as the question
  rewrite                text not null check (rewrite in ('applied', 'failed_fallback', 'not_needed')),
  rewrite_version        text,
  text                   text not null,         -- as delivered
  status                 text not null check (status in ('complete', 'interrupted')),
  chat_provider          text not null,
  chat_model             text not null,
  chat_model_reported    text,
  chat_model_revision    text,
  thinking_mode          text not null check (thinking_mode in ('enabled', 'disabled')),
  temperature            numeric,
  generation_params_hash text not null,
  prompt_version         text not null,
  confidence_version     text,
  confidence_state       text check (confidence_state in
                           ('scored', 'unverified', 'insufficient_support')),
  confidence_band        text check (confidence_band in ('high', 'medium', 'low')),
  confidence_base        numeric(4, 3),         -- persisted, never rendered
  claims_total           smallint check (claims_total >= 0),
  claims_verified        smallint check (claims_verified >= 0),
  claims_partial         smallint check (claims_partial >= 0),
  claims_failed          smallint check (claims_failed >= 0),
  claims_uncited         smallint check (claims_uncited >= 0),
  claims_unchecked       smallint check (claims_unchecked >= 0),
  verified_documents     smallint check (verified_documents >= 0),
  gates_applied          text[],                -- gate ids, in the order applied
  confidence_params      jsonb,                 -- every constant applied, cut points included
  created_at             timestamptz not null default now(),  -- first delivered token
  completed_at           timestamptz,

  -- A band exists if and only if the answer was scored. A base exists wherever a
  -- share is defined: `scored` must have one, `insufficient_support` may leave it
  -- null because a share over zero claims — an empty evidence set — does not exist.
  constraint answers_band_shape check (
       (confidence_state is null                  and confidence_band is null     and confidence_base is null)
    or (confidence_state = 'scored'               and confidence_band is not null and confidence_base is not null)
    or (confidence_state = 'insufficient_support' and confidence_band is null)
    or (confidence_state = 'unverified'           and confidence_band is null     and confidence_base is null)
  ),
  -- An interrupted answer has no claims and no band; it reads as "support not checked".
  constraint answers_interrupted_shape check (
    status = 'complete'
    or (claims_total is null and confidence_state = 'unverified')
  ),
  -- A standalone query exists if and only if the rewrite produced one.
  constraint answers_rewrite_shape check (
       (rewrite = 'not_needed'      and standalone_query is null      and rewrite_version is null)
    or (rewrite = 'applied'         and standalone_query is not null  and rewrite_version is not null)
    or (rewrite = 'failed_fallback' and standalone_query is null      and rewrite_version is not null)
  )
);
-- The History window and the carry-forward tier both read this path, oldest first.
create index answers_conversation on answers (conversation_id, created_at, id);

create table answer_claims (
  id        uuid primary key default uuidv7(),
  answer_id uuid not null references answers(id) on delete cascade,
  seq       smallint not null check (seq >= 0),  -- persisted order, never inferred from text
  text      text not null,
  unique (answer_id, seq)
);
-- A claim's verification state is derived, never stored: the worst of its
-- citations, `uncited` when it has none, `unchecked` when no complete run exists.

create table citations (
  id              uuid primary key default uuidv7(),
  claim_id        uuid not null references answer_claims(id) on delete cascade,
  chunk_id        uuid not null,                -- snapshot: no FK, may outlive its chunk
  document_id     uuid not null,                -- snapshot: no FK
  char_start      integer not null,             -- the chunk's range, in canonical markdown
  char_end        integer not null,
  quote_requested text,                         -- the generator's retyping, when it gave one
  quote_start     integer,                      -- where that quote was actually located
  quote_end       integer,
  display_quote   text,                         -- the canonical slice shown; null if not located
  document_title  text not null,                -- snapshot for rendering after deletion
  page_start      integer,
  page_end        integer,
  page_labels     text[]
);
create index citations_claim on citations (claim_id);

create table answer_evidence (
  answer_id   uuid not null references answers(id) on delete cascade,
  chunk_id    uuid not null,                    -- snapshot: no FK
  document_id uuid not null,                    -- snapshot: no FK
  source      text not null check (source in ('carried', 'retrieved')),
  fused_rank  smallint,                         -- null for carried; observability only, never API
  primary key (answer_id, chunk_id)
);

-- One run per verification attempt. Re-deriving after a threshold change adds
-- a run; it never rewrites a verdict. The newest complete run is what shows.
create table verification_runs (
  id                uuid primary key default uuidv7(),
  answer_id         uuid not null references answers(id) on delete cascade,
  state             text not null check (state in ('running', 'complete', 'degraded')),
  verifier_name     text not null,
  verifier_revision text not null,
  thresholds        text not null,              -- '0.70/0.50', as applied
  elapsed_ms        integer,
  failure_reason    text check (failure_reason in
                      ('budget_exceeded', 'verifier_unavailable', 'crashed')),
  started_at        timestamptz not null default now(),
  completed_at      timestamptz
);
create index verification_runs_answer on verification_runs (answer_id, started_at desc);

create table citation_verdicts (
  run_id           uuid not null references verification_runs(id) on delete cascade,
  citation_id      uuid not null references citations(id) on delete cascade,
  verdict          text not null check (verdict in ('verified', 'partial', 'failed')),
  score            numeric(4, 3),               -- null when the span gate failed
  diagnostic_score numeric(4, 3),               -- scored even when the span gate failed
  reason           text check (reason in ('quote_not_found', 'not_in_evidence_set', 'unsupported')),
  primary key (run_id, citation_id)
);
-- The matched span lives on `citations`, which every verdict points at; locating a
-- quote is deterministic, so a per-run copy of the offsets could only ever diverge.

-- ─── admissions: idempotency and one answer in flight ───────────────────

-- Exists from admission, before any Answer row does, so the idempotency key is
-- reserved and "one in flight per Conversation" is a constraint rather than a check.
create table answer_requests (
  id              uuid primary key default uuidv7(),
  owner_id        uuid not null references accounts(id) on delete cascade,
  conversation_id uuid not null references conversations(id) on delete cascade,
  idempotency_key uuid not null,
  state           text not null default 'in_flight'
                  check (state in ('in_flight', 'answered', 'failed')),
  answer_id       uuid unique references answers(id) on delete set null,
  error_code      text,
  created_at      timestamptz not null default now(),
  settled_at      timestamptz
);
create unique index answer_requests_key on answer_requests (owner_id, idempotency_key);
create unique index answer_requests_one_inflight on answer_requests (conversation_id)
  where state = 'in_flight';
create index answer_requests_owner_inflight on answer_requests (owner_id)
  where state = 'in_flight';
create index answer_requests_retention on answer_requests (settled_at)
  where settled_at is not null;

-- ─── cost ledger ────────────────────────────────────────────────────────

-- Immutable: one row per provider call attempt. No update, no delete; every
-- total is a query. owner_id nulls when the Account goes, so the deployment's
-- month stays summable with the payer gone.
create table model_calls (
  id                       bigserial primary key,
  created_at               timestamptz not null default now(),
  owner_id                 uuid references accounts(id) on delete set null,
  scope                    text not null check (scope in ('product', 'eval')),
  subject_kind             text not null check (subject_kind in
                             ('answer', 'ingestion', 'rewrite', 'eval', 'judge')),
  subject_id               uuid,                -- loose: no FK (eval ids are file-based)
  attempt                  smallint not null default 1 check (attempt >= 1),
  provider                 text not null,
  model                    text not null,
  price_key                text not null,
  price_version            text not null,
  is_peak                  boolean not null,
  prompt_cache_hit_tokens  integer,
  prompt_cache_miss_tokens integer,
  completion_tokens        integer,
  reasoning_tokens         integer,
  token_source             text not null check (token_source in ('reported', 'estimated')),
  cost_micros              bigint not null check (cost_micros >= 0),
  outcome                  text not null check (outcome in ('ok', 'error', 'aborted'))
);
create index model_calls_owner_window on model_calls (owner_id, scope, created_at);
create index model_calls_window on model_calls (scope, created_at);
create index model_calls_subject on model_calls (subject_kind, subject_id);

-- ─── rules that are comments ────────────────────────────────────────────
--
-- Invariants a CHECK cannot reach across rows or tables. Each is asserted by
-- the write path that could break it, and by a test:
--
--   1. chunks.text = document_content.canonical_markdown[chunk.char_start:char_end],
--      byte for byte. The span gate addresses this range, so drift here is
--      silent verification failure.
--   2. answers.owner_id = conversations.owner_id. Tenancy is denormalised, so it
--      can disagree. (Chunks carry no owner: every read of a chunk joins
--      `documents` for its status, and that is where the tenant check happens.)
--   3. chunks.id = uuid5(document_id, chunker_version, chunk_index), and equals
--      the Qdrant point id.
--   4. The four embedding columns on a chunk equal the document's current
--      indexing generation and name the collection the vector was written to.
--   5. model_calls.owner_id is not null whenever scope = 'product' — except
--      after the Account is deleted, which is what `on delete set null` is for.
--
-- Retention (owned by the maintenance sweep, one task each, all idempotent):
--
--   answer_requests  settled more than 24 h ago                  delete
--   sessions         revoked or expired more than 30 days ago    delete
--   login_attempts   last_failure_at older than 1 day            delete
--   model_calls      never                                       —
--   everything else  lifetime of its Account
