# Cost and pricing: what providers charge, what they report, and how to price a call

The decision this supports is recorded in
[ADR 0008](../adr/0008-price-every-call-and-gate-spend-before-the-call.md). This document holds the
evidence: the rate card as read, the usage fields a call returns, the ambiguity that remains, and the
alternatives the ADR rejected. Rates below are a snapshot, not a constant — the card in
`config/pricing.toml` is the operative copy, and this table records what it was seeded from.

## The rate card, read 2026-11-19

USD per 1,000,000 tokens. Peak hours are 01:00–04:00 and 06:00–10:00 UTC, Monday to Friday,
excluding Chinese public holidays; every other hour is off-peak at exactly half the peak rate.

| Model | Tier | Input, cache hit | Input, cache miss | Output |
| --- | --- | --- | --- | --- |
| `deepseek-flash` (V4.1-Flash-1017) | off-peak | $0.003 | $0.15 | $0.60 |
| `deepseek-flash` | peak | $0.006 | $0.30 | $1.20 |
| `deepseek-v4-pro` (V4-Pro-0813) | off-peak | $0.022 | $0.66 | $1.98 |
| `deepseek-v4-pro` | peak | $0.044 | $1.32 | $3.96 |
| TEI `Qwen/Qwen3-Embedding-0.6B` | local | — | — | — |

Consequences a reader should take from the table rather than re-derive:

- **Cache hits dominate a RAG bill.** A 4,000-token prompt that hits the cache costs `$0.000012` of
  input; the same prompt missing costs `$0.0006` — 50×. Pricing `prompt_tokens` means overstating the
  common case by an order of magnitude.
- **The day has two prices.** The same request at 02:00 UTC costs twice what it costs at 23:00, so a
  stored `is_peak` per row is what lets a cost chart explain its own spikes.
- **There is no batch discount.** DeepSeek's "off-peak" is the discount mechanism; unlike OpenAI,
  Anthropic and Google there is no half-price batch endpoint. A nightly run scheduled outside peak is
  therefore the only lever, which is what ADR 0006 already assumes.
- **There is no per-model cache-write charge.** The Chat Completions schema lists no cache-creation
  field, so a miss is priced once at the miss rate and nothing else.

## What a call reports

`usage` on Chat Completions, per DeepSeek's schema:

| Field | Meaning | Use in the ledger |
| --- | --- | --- |
| `prompt_tokens` | all input tokens; equals hit + miss | denominator only — never priced |
| `prompt_cache_hit_tokens` | input tokens served from the context cache | priced at the hit rate |
| `prompt_cache_miss_tokens` | input tokens not served from the cache | priced at the miss rate |
| `prompt_tokens_details.cached_tokens` | same value as `prompt_cache_hit_tokens` | ignore; adding both double-counts |
| `completion_tokens` | generated tokens | priced at the output rate |
| `completion_tokens_details.reasoning_tokens` | a breakdown **within** `completion_tokens` | recorded, never priced separately |
| `total_tokens` | prompt + completion | never priced |

Streaming carries no usage-only chunk: the counts ride the last content chunk, with a non-null
`finish_reason`. That is the seam ADR 0007 normalises into a terminal usage event — which is also why
a stream that breaks before that chunk leaves the ledger with an estimate rather than a number.

The API returns **no dollar amount and no cache-hit-rate field**; both are derived here. That matters
for the ADR's fail-closed rule: nothing upstream can be consulted to check our arithmetic, so the
rate card's `version` is the only audit trail a mispriced row will have.

## What remains unverified

- **Whether TEI's OpenAI-compatible `/v1/embeddings` returns a `usage` block.** The OpenAI shape
  includes `{prompt_tokens, total_tokens}`, and TEI's native `/embed` response carries a `Metadata`
  object whose fields are not documented as token counts. Both branches are handled: read `usage` when
  present, otherwise estimate with the chunker's tokenizer and flag `token_source = 'estimated'`. The
  call is local and priced at zero at launch, so the ambiguity costs nothing today and matters only if
  a hosted embedding provider is configured.
- **Whether a response's `model` field echoes the served revision** rather than the alias — the same
  open question ADR 0007 records, which is why `known_revision` is maintained by hand.
- **Whether DeepSeek's peak calendar will stay two windows.** It has moved more than once (off-peak
  rates withdrew and returned, the peak policy changed with V4.1), which is why windows are data in a
  file rather than a comparison in a function.

## Maintaining the card

The chore is deliberately manual and deliberately small:

1. Read the provider's pricing page when a rate change is announced — or monthly, whichever comes
   first — and add a new `[[price]]` block with a later `effective_from`. Never edit an existing
   block's rates: rows already written name the old version, and a change of history is exactly what
   the ledger exists to prevent.
2. Bump the card's `version`.
3. If the peak policy moved, update `[peak]` and its unit tests; the fixed-clock tests cover
   off-peak, inside-window, both window edges and a weekend.
4. Refresh `holidays_utc` once a year from the published Chinese public holiday calendar.

A missed refresh is visible rather than silent: rows written after the vendor's change still carry the
old `price_version`, so a cost chart that jumps against a flat token count points at the card.

## Options compared

### Where prices live

| Option | For | Against |
| --- | --- | --- |
| Checked-in TOML, frozen at boot, `price_version` on each row | diff-reviewable; no admin surface; history immutable; testable windows | a price change needs a deploy; the card can drift until someone refreshes it |
| Postgres table seeded by migration | updatable at runtime | a mutable row decides what an answer cost; needs the admin surface ADR 0007 refused; a migration per vendor change |
| Flat per-model rate in the registry | one column, one multiplication | wrong by 2× across the day and ~50× across the cache; the registry would carry volatile prices it was designed to exclude |
| Provider introspection | always current | no provider here exposes a per-call price or a rate API; a billing endpoint would be a second product surface |

### How spend is enforced

| Option | For | Against |
| --- | --- | --- |
| Admission check on an upper-bound estimate, then reconcile | no money past the cap; refusal precedes the stream; the user never sees a truncated answer | a caller near the line can be refused while under it (bounded, and priced at the cache-miss rate on purpose) |
| Post-hoc: answer, then flag | no false refusals | overshoot every conversation at the boundary; a stream cut mid-answer; the cap is really a target |
| Estimate with a grace margin | fewer refusals near the line | "hard cap" becomes a suggestion; the margin has no measurement behind it |
| Meter and never block | nothing to specify | a public deployment with an invite-gated audience can still drain the key |

### Ledger grain

| Option | For | Against |
| --- | --- | --- |
| One row per call attempt, retries and aborts included | the ledger is the call log; a spike is explainable; matches what the vendor bills | more rows (thousands per month, not millions) |
| One aggregate row per answer or job | fewer rows, simpler read | cannot distinguish retries from expensive answers; loses stage attribution |
| Rows per call, counting only successes | budgets match delivered answers | recorded spend diverges from the invoice |

## Sources

- [DeepSeek Models & Pricing](https://api-docs.deepseek.com/quick_start/pricing) — models, versions,
  the four-tier rate card, peak windows, the off-peak-is-half rule, retirement of the legacy names.
- [DeepSeek Chat Completions API](https://api-docs.deepseek.com/api/create-chat-completion) — the
  `usage` object, its required fields, `prompt_tokens_details.cached_tokens`, and the
  `completion_tokens_details.reasoning_tokens` breakdown.
- [DeepSeek Context Caching](https://api-docs.deepseek.com/guides/kv_cache) — the cache-prefix model and
  the two hit/miss counters.
- [DeepSeek Thinking Mode](https://api-docs.deepseek.com/guides/thinking_mode) — default `max_tokens`
  of 8 K non-thinking and 64 K thinking, which is why the admission ceiling is our own constant.
- [OpenAI Create embeddings](https://developers.openai.com/api/reference/resources/embeddings/methods/create)
  — the `usage` shape TEI's compatible endpoint may or may not emit.
- [TEI proto](https://github.com/huggingface/text-embeddings-inference/blob/main/proto/tei.proto) —
  `EmbedResponse`'s metadata object, which does not document token counts.
