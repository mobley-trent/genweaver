# Conversation memory is a small verbatim window over a pinned carry-forward

**Status:** accepted
**Date:** 2026-11-24

Memory in this product is three things and nothing else. A follow-up's Question is first turned into a
**Standalone query** by a small `deepseek-flash` call, so retrieval never runs on text whose subject is
missing. The chunks the earlier Answers in the Conversation cited are then re-admitted as **carried
chunks** — a pinned tier of at most six inside the ≤20 Evidence set, honoured whatever the ranking
says. And the generator is given a **verbatim History window** of at most four exchanges and 2,000
tokens: the questions and answers as delivered, with their citation markers stripped. Nothing is
summarised, nothing is embedded, no new table exists, and a new Conversation remembers nothing.

**Rewriting is not one of the options; it is the premise.** A citation is only valid if its chunk is
in *this* Answer's Evidence set ([ADR 0003](./0003-verified-citations-with-a-local-verifier.md)), and
confidence is computed per Answer over those verdicts
([ADR 0004](./0004-confidence-is-a-support-share-not-a-probability.md)). So a correct follow-up that
cites last turn's chunk scores zero support unless that chunk is re-eligible this turn — every claim
comes back `not_in_evidence_set`, the answer lands in `insufficient_support`, and the product blames
the documents for a memory bug. Re-admission is therefore a correctness requirement, not an
optimisation, which is why the three mechanisms the ticket offered — window, summary, retrieval — only
ever differed in *what the generator additionally sees*. That choice was made: it is the window.

**The rewrite has a deadline of 5 seconds, and the deadline belongs to the step, not the attempt.**
`REWRITE_DEADLINE_SECONDS = 5` is a launch default in exactly the sense
[ADR 0007](./0007-own-the-model-seams-and-fail-closed.md) records its chat deadlines: a named constant
with a documented default, neither a per-call argument nor a deployment knob, moved only by a reviewed
diff naming the measurement that moved it. It bounds the **whole rewrite step**: ADR 0007's retry policy
is not repealed, but a step that has spent its allowance falls through to the raw Question and the
pinned tier as `failed_fallback` rather than starting another attempt, because this call sits *before*
retrieval and its delay is wholly additive to time-to-first-token. Five seconds is judgement, not
measurement — a 200-token non-thinking call should answer in a fraction of it, and one slower than that
costs the person more than a resolved Standalone query is worth.

**The tier is pinned because a guarantee that depends on rank is not a guarantee.** Fusion is ordinal
([ADR 0002](./0002-tenant-partitioned-hybrid-retrieval-without-sparse-vectors.md)): a prefetch branch
of carried chunks competes with two retrieved branches, and RRF arithmetic can push a chunk into 21st
place for having appeared in only one list — exactly the case this tier exists to survive. So carried
chunks occupy reserved slots, are marked `carried` on the wire, and are **hydrated from Postgres, not
from the vector store**: a pinned chunk was never retrieved, so it needs no vector, and a reindex that
has not run yet — or a Qdrant blink — cannot empty the tier and turn every follow-up into
`insufficient_support`. Carried ids whose chunk row is gone (the source was deleted, per
[ADR 0009](./0009-serve-rest-with-sse-over-fetch.md)) are silently dropped; a follow-up to a deleted
document is a miss, not an error.

**Small is the point of the window, not a concession to cost.** A 6,000-token window retains the
*superseded* turn alongside the correction that overrides it, handing the model two conflicting
figures with nothing but recency to rank them; the **correction** eval item exists precisely to catch
a system that resurrects the stale value, and the cheapest way to pass it is to have already dropped
the value. What the wider window would have carried that is genuinely useful — the document a referent
came from — is what the pinned tier re-supplies independently of prose. Longer prompts also buy less
than they cost: retrieval-augmented accuracy saturates well before retrieval recall does, and models
use the middle of a long context worst of all
([Liu et al., TACL 2024](https://aclanthology.org/2024.tacl-1.9); evidence in
[conversation memory](../research/conversation-memory.md)). The window is 2,000 tokens *optional*
plus one mandatory most-recent exchange, which at `deepseek-flash` rates is roughly
**$0.0003 off-peak / $0.0006 peak** per turn on a ~12,000-token prompt — about a sixth of the prompt's
cost, and nothing like the cliff a 1M-token context invites you to believe is free.

**Summarising was rejected on exactness before it was rejected on cost.** A running summary needs a
call it would have to be triggered by, a table to live in, and a version to be compared across — and it
deletes the verbatim wording that the correction item needs, that the span gate grounds a quote in, and
that an entailment check can be honest about. It also rewrites the prompt prefix every time it is
refreshed, so it forfeits whatever provider caching the prompt had earned. A Conversation that
persists a summary would additionally reopen the glossary's own definition of *Conversation* as holding
no derived state — a legitimate move, but one this product does not need to make. Retrieval over history
was rejected for putting a second, incomparable embedding space beside the chunk space and for
retrieving text that no citation can ever point at, which is the one thing this product does not do.
Both ship as **eval arms**, recorded in the registry and measured by the multi-turn items, and either
may be promoted only as an eval outcome.

**Memory reads, it does not store.** The History window is `answers` with `status = 'complete'`,
ordered by creation; carried chunks are the `chunk_id`s on those Answers' citation rows, which already
exist. So the Postgres data model gains **no table, no column and no migration** for memory, and an
Account's retention obligations are unchanged: delete the Conversation and memory is gone with it,
because memory was never anywhere else.

## Considered Options

- **A rolling summary of older turns** — compresses unbounded history, at the price of an extra call, a
  table, a version, the deletion of the exact text the gates need, and a prompt prefix rewritten on
  every refresh.
- **Retrieval over embedded past turns** — the most capable on paper, and a second retrieval space whose
  results can never be cited, so its contribution is invisible to every verification-based gate.
- **A larger verbatim window (4,000–6,000 tokens)** — more recall of distant turns, and it keeps
  superseded values in the prompt next to their corrections.
- **Carrying only the immediately previous Answer's citations** — smaller, deterministic, and blind to
  "and the second one?" asked three turns later.
- **Feeding carried chunks through fusion as an ordinary prefetch branch** — no reserved slots, and no
  rule that survives an adverse ranking.
- **Validating carried chunks against Qdrant** — one storage rule instead of two, and a follow-up stops
  working whenever the vector store is behind or briefly unavailable.
- **Keeping prior citation markers in the History window** — the generator would cite `[3]` this turn
  meaning last turn's `[3]`, producing `failed` citations by construction.
- **Pooling memory across a person's Conversations** — personalisation rather than retrieval: it would
  need its own verification and retention story, and it is outside this effort's destination.
- **Storing a per-turn transcript or a derived turn table** — a second copy of what `answers` already
  holds, and a fact about the Conversation that the glossary says the Conversation does not have.

## Consequences

- **Two prompt contracts exist** — the rewrite and the answer — each with its own version, recorded
  separately on the Answer, so a nightly rewrite-fidelity drop and a generation-quality drop are
  attributable. Provenance also records `rewrite: applied | failed_fallback | not_needed`.
- **A rewrite is a metered call**: a `model_calls` row with `subject_kind = 'rewrite'`, priced per
  attempt, inside the admission estimate — it is spent before context assembly exists, which is the gap
  [ADR 0008](./0008-price-every-call-and-gate-spend-before-the-call.md) left open.
- **A rewrite failure never fails a request.** The turn proceeds on the raw Question plus the pinned
  tier, recorded as `failed_fallback`; a rewrite outage must not render as "your question failed".
- **The wire gains three facts** — carried and retrieved counts, an origin flag on each Evidence-set
  member, and the rewrite state — so a user can tell a followed-up question from a fresh one. This
  amends the contract of [ADR 0009](./0009-serve-rest-with-sse-over-fetch.md) rather than extending
  it quietly, and gives the UI the label it needs for carried evidence.
- **Multi-turn evaluation splits along determinism, per
  [ADR 0006](./0006-gate-determinism-exactly-and-generation-statistically.md):** the PR gate replays a
  hand-authored gold Standalone query and its frozen vector — never a live rewrite — and also gates the
  assembly assertion that a superseded exchange is out of the History window; nightly scores the live
  rewrite and the generation.
- **The History window's position in the prompt is still open**, and it matters: models use the middle
  of a context worst. That is context assembly's decision, not memory's.
- **Fog cleared**: context assembly and prompt packing is now specifiable and has its own ticket; the
  fog that remains is the reranker's token budget, the copy for a miss, observability, and non-PDF
  ingestion.
- **Unmeasured**: no window size, no tier cap, no rewrite ceiling and no rewrite deadline here has a
  measurement behind it. Two thousand tokens, four exchanges, six carried chunks, a 200-token rewrite
  and `REWRITE_DEADLINE_SECONDS = 5` are launch defaults, moved by a reviewed diff citing multi-turn
  eval results or a latency histogram — the rule
  [ADR 0007](./0007-own-the-model-seams-and-fail-closed.md) applies to its provisional numbers.
