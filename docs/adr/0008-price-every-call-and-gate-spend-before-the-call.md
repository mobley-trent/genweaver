# Price every provider call, and gate spend before the call

**Status:** accepted
**Date:** 2026-11-24

Cost tracking here is two mechanisms, not one. A **usage ledger** records every provider call
attempt and the money it cost, priced at write time against a checked-in **rate card** that knows
about cache hits and peak windows. A **budget** is a ceiling over a window, and it is enforced by an
**admission check** that prices an answer's upper bound before the first token is requested, never by
discovering the overspend afterwards.

Three facts force this shape. DeepSeek bills input at two rates depending on the context cache
(a cache hit is roughly one fiftieth of a miss: `$0.003` vs `$0.15` per million on `deepseek-flash`
off-peak), so pricing `total_tokens` at one rate is wrong by an order of magnitude on a RAG prompt
that repeats a document. It bills every rate at double during peak windows (01:00–04:00 and
06:00–10:00 UTC, Monday to Friday), so the same request costs twice as much at 02:00 as at 23:00. And
it reports those two input counts separately, alongside `completion_tokens` and a
`completion_tokens_details.reasoning_tokens` that is a *breakdown* of completion rather than a
fourth amount — so the ledger can apply each rate to the count it belongs to instead of guessing.

The alternative — one price per model, cost computed when someone reads the row — fails twice. It
misprices the two dimensions that dominate the bill, and it makes history mutable: when DeepSeek
changes a rate, every past answer's cost changes with it, and "what did that run cost" stops being a
fact. `price_version` on the row is what keeps the ledger a record.

## The ledger

One immutable row per provider call **attempt**. Retries are rows. A stream that broke after the
first token is a row, because the provider billed the tokens it had already sent. A request that
timed out before any bytes arrived is a row with zero tokens and an `outcome` of `error`. Nothing
updates a row and nothing deletes one; aggregation is always a query, never a second stored total.

```sql
-- shape, not the final DDL: Specify the Postgres data model owns the schema
create table model_calls (
  id            bigserial primary key,
  created_at    timestamptz not null default now(),
  owner_id      uuid references users(id),        -- the Account that caused it; null for eval
  scope         text not null check (scope in ('product', 'eval')),
  subject_kind  text not null check (subject_kind in ('answer', 'ingestion', 'eval', 'judge')),
  subject_id    uuid,                             -- answer or document id; null when detached
  attempt       smallint not null default 1,
  provider      text not null,
  model         text not null,
  price_key     text not null,
  price_version text not null,
  is_peak       boolean not null,
  prompt_cache_hit_tokens  integer,
  prompt_cache_miss_tokens integer,
  completion_tokens        integer,
  reasoning_tokens         integer,
  token_source  text not null check (token_source in ('reported', 'estimated')),
  cost_micros   bigint not null,
  outcome       text not null check (outcome in ('ok', 'error', 'aborted'))
);

create index model_calls_owner_window on model_calls (owner_id, scope, created_at);
create index model_calls_window       on model_calls (scope, created_at);
```

`token_source` is the honesty column. When the provider reports usage — the normal path, including
the terminal usage event on a stream's last content chunk — the counts are `reported`. When it never
arrives (a stream that died, a timeout, an embedding response with no `usage` block), the adapter
estimates from the request and whatever text came back with the tokenizer the chunker already
vendors, and marks the row `estimated`. The row is still written and still priced: a call we cannot
count is not a call that was free. The eval report publishes the estimated share so a drift between
our ledger and DeepSeek's invoice has a place to start.

`cost_micros` is integer micro-US-dollars. Because the rate card's unit is dollars per million
tokens, the arithmetic is exact and short:

```
cost_micros = round(hit × hit_rate + miss × miss_rate + completion × out_rate)
```

with `Decimal` inputs and half-up rounding at the end — tokens × (USD / 1M) is already micro-USD.
A local call prices to zero and says so through its price key rather than by being absent.

Splitting chat usage into "thinking" and "answer" tokens is deliberately not done: `reasoning_tokens`
is part of `completion_tokens` and adding it again would double-bill, while removing it would price
thinking at zero. It is recorded as a breakdown for diagnosis only.

Ingestion writes rows too, against the document's Account, under the same subject rules. At launch
embeddings are local and priced at zero, so ingestion spends nothing; if a hosted embedding provider
is configured, the same admission check applies to a job's batches and the same rows debit the
Account.

## The rate card

Prices are a checked-in file, `config/pricing.toml`, loaded once at boot into a frozen table. They
are **not** in Postgres: a mutable row deciding what an answer cost is the same mistake ADR 0007
refused for model selection, and it would need an admin surface this project does not have. A price
change is a commit whose diff shows the old and new rate.

```toml
version = "2026-11-19"

[peak]                                   # DeepSeek's higher rate applies inside these windows
weekdays     = [1, 2, 3, 4, 5]           # ISO weekday: Monday..Friday
windows_utc  = ["01:00-04:00", "06:00-10:00"]
holidays_utc = []                        # Chinese public holidays, hand-maintained

[[price]]                                # USD per 1M tokens
key            = "deepseek-flash"
effective_from = "2026-09-10"
input_cache_hit  = { off_peak = "0.003", peak = "0.006" }
input_cache_miss = { off_peak = "0.15",  peak = "0.30"  }
output           = { off_peak = "0.60",  peak = "1.20"  }

[[price]]
key            = "deepseek-v4-pro"
effective_from = "2026-11-19"
input_cache_hit  = { off_peak = "0.022", peak = "0.044" }
input_cache_miss = { off_peak = "0.66",  peak = "1.32"  }
output           = { off_peak = "1.98",  peak = "3.96"  }

[[price]]
key            = "local-cpu"
effective_from = "2026-11-24"
input_cache_hit  = { off_peak = "0", peak = "0" }
input_cache_miss = { off_peak = "0", peak = "0" }
output           = { off_peak = "0", peak = "0" }
```

`price_version` is the card's `version` plus the key's `effective_from`, so a row is self-describing
without a join. The registry's `price_key` must resolve at boot: **a configured model whose price key
is missing from the card fails startup** rather than running and pricing calls at zero. Failing to
boot is the fail-closed behaviour ADR 0007 established for missing API keys, applied to missing
prices.

The peak calendar is data for a reason: a `is_peak` computed from a comment in a docstring is not
testable, while a table with `weekdays`, `windows_utc` and `holidays_utc` is — the ADR's own
out-of-window/peak/edge cases become unit tests with a fixed clock. The holiday list is
hand-maintained and refreshes once a year; a missed holiday overstates cost for those hours by 2×,
which is the safe direction for a budget, and the research doc records that this is a known
imprecision rather than a bug report waiting to happen.

## Budgets and the admission check

| Budget | Window | Binding | Default | Setting |
| --- | --- | --- | --- | --- |
| Account | UTC calendar month | hard — refuses | `$5.00` | `BUDGET_ACCOUNT_MONTHLY_USD` |
| Account | UTC calendar day | soft — warns | `$1.00` | `BUDGET_ACCOUNT_DAILY_SOFT_USD` |
| Deployment | UTC calendar month | hard — refuses | `$50.00` | `BUDGET_DEPLOYMENT_MONTHLY_USD` |

A calendar window is what "this month's spend" means to whoever reads the usage page, and it matches
how a prepaid balance is topped up. **Admins are exempt from the Account budgets but not from the
deployment ceiling**: an operator must be able to fetch a document at $5.01, and no role must be able
to drain the key alone.

The admission check runs after context assembly (the prompt's size is known) and before the chat
call, and computes:

```
estimate_micros =
    prompt_tokens × input_cache_miss_rate(now)     # assume no cache hit: the conservative direction
  + ANSWER_OUTPUT_CEILING × output_rate(now)       # 2048 tokens, thinking off
  + ADMISSION_VERIFICATION_ALLOWANCE_MICROS        # 0 while the verifier is local
```

Two choices in that formula are deliberate. Pricing the estimate at the **cache-miss** rate means
admission can only err toward refusing a caller who is in fact under budget, never toward admitting
one past it. Pricing the output at a **configured answer ceiling** rather than the model's 384 K
maximum is what keeps the check usable: at peak flash rates a 64 K hold is `$0.077` against a real
answer that costs `$0.002`, so the ceiling would refuse everyone but the very fresh Account. The
ceiling is a named constant with a documented default, moved by the same reviewed-diff rule ADR 0007
applies to deadlines and ADR 0006 to its thresholds.

Refusal is total and precedes the stream: no provider call is made, no token is emitted, so the
client never renders half an answer and then stops. The error is a typed, non-retryable
`budget_exhausted` carrying the budget's window, its limit, the spend so far and the reset instant;
the HTTP status and body shape belong to
[Set the API surface and streaming contract](https://github.com/mobley-trent/genweaver/issues/14).
The deployment ceiling carries a distinct code, because "your Account is out of budget" and "this
deployment is out of budget, tell the operator" are different messages to different people.

Concurrency is accepted rather than locked: two questions admitted simultaneously each pass against
the same remaining balance and can overshoot by at most one answer's actual cost each. A row lock per
Account would serialise every question in the deployment to protect against cents, and the reconcile
step already writes the truth.

Spend is summed from `scope = 'product'` rows only. Eval runs, the judge and the PR smoke write
`scope = 'eval'` rows owned by nobody: a nightly run must not be able to lock a member out of their
own quota, and ADR 0006's `$0.25` nightly ceiling becomes a `sum(cost_micros) where scope = 'eval'`
query rather than a hope. Both scopes share the table, so total key spend is still one query.

## The two queries that matter

```sql
-- Account spend in the current UTC calendar month (hard budget)
select coalesce(sum(cost_micros), 0) as spent_micros
from model_calls
where owner_id = $1
  and scope = 'product'
  and created_at >= date_trunc('month', now() at time zone 'utc') at time zone 'utc';

-- current UTC day, for the soft threshold: same predicate with 'day'
-- deployment ceiling: the same predicate with the owner_id clause dropped, scope still 'product'
-- nightly cost from ADR 0006: same predicate with scope = 'eval'
```

Both are index-covered by `model_calls_owner_window` and `model_calls_window`. The usage page
additionally groups by `date_trunc('day', created_at at time zone 'utc')` for its per-day strip.

## What is shown

| Where | What | Who |
| --- | --- | --- |
| Answer | provider, model, attempt, hit/miss/completion tokens, `token_source`, micro-USD, outcome — a collapsed diagnostics block | the Answer's owner |
| Conversation | total micro-USD across its answers | the Conversation's owner |
| Usage page | spent today, spent this month, remaining, next reset, per-day strip | any Account, own figures only |
| Admin view | per-Account spend table, deployment total, eval spend, both ceilings | admins |

Cost is presented the way confidence is: a number with its units beside the evidence that produced
it, never a score out of context. An answer's cost is almost entirely its chat call — query
embeddings are local and verification is local — which the diagnostics block makes visible instead
of leaving the reader to wonder why "verified citations" appear free.

The soft daily threshold produces a banner, not a refusal: `You've spent $1.04 of your $1.00 daily
allowance today`. A hard refusal reads `This account has reached its monthly budget of $5.00. It
resets on 1 January 2027 (UTC).` The deployment's reads `This deployment has reached its monthly
budget. Tell the operator.` No refusal offers a "retry", because retrying cannot succeed until the
window rolls.

## Considered Options

- **A Postgres price table seeded by migration** — updatable without a deploy, and it turns "what did
  this cost" into a mutable fact needing an admin surface; rejected for the reason ADR 0007 rejected a
  DB-backed model registry.
- **One flat rate per model** — one column and one multiplication, and wrong by 2× across the day and
  ~50× across the cache, in both directions over a month.
- **Cost computed at read time from current prices** — no `price_version` needed, and historical
  answers silently re-price whenever the vendor changes the card.
- **One aggregate row per answer or ingestion job** — a tidier ledger, minus the retry and abort that
  explain the spike, and minus the ability to attribute an attempt to a stage.
- **Only successful calls counted** — budgets track answers delivered rather than money spent.
- **Post-hoc enforcement** — no false refusals, and an overshoot per conversation plus a stream that
  can die mid-answer.
- **Per-Account budgets only, or a global ceiling only** — the first exposes the owner's balance to
  every invited Account behaving reasonably; the second lets one Account consume the deployment's
  month.
- **Metering local calls not at all** — smaller ledger, and the answer's own diagnostics can no longer
  say what it cost or why.

## Consequences

- Every answer can state what it cost and every conversation its total, from rows that never change.
  The eval harness gets `$0.25`-nightly as a measurement instead of an estimate, and the observability
  fog inherits a table to chart rather than a design to finish.
- The rate card is **volatile data in a stable shape**: DeepSeek has changed these rates four times in
  V4's life and moved the peak policy twice. Refreshing `config/pricing.toml` is an operational chore
  with a written procedure in the research doc, and the ledger's `price_version` is what makes an
  unrefreshed card visible rather than silent: rows written after a change still name the old version.
- `$0.25` per nightly run is now a query, and so is the drift between our ledger and the invoice —
  `estimated` rows are the first place to look, which is why the definition exists.
- The Postgres data model ticket inherits this table's shape, its two indexes, and the rule that
  deleting an Account must not cascade-delete its usage rows: cost history outlives the Account so the
  deployment's month stays summable.
- The API surface ticket inherits `budget_exhausted`, its two subjects (Account, deployment) and the
  rule that refusal precedes streaming; the UI ticket inherits four surfaces (answer diagnostics,
  conversation total, usage page, admin table) and the two refusal messages.
- The admission ceiling and the daily soft threshold have **no measurement behind them** — nothing has
  run yet. They carry documented defaults and move only by a reviewed diff citing a month of real
  spend, exactly as ADR 0007's deadlines do.
- Touring the card's windows is unit-testable with a fixed clock; the holiday list is not, and a missed
  holiday overstates cost for those UTC hours, which is the conservative direction for a ceiling.

See [`docs/research/cost-and-pricing.md`](../research/cost-and-pricing.md) for the rate card as read on
2026-11-19, the exact usage fields, and the sources this rests on.
