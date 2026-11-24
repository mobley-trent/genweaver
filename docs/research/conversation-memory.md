# Conversation memory: the mechanisms, the provider's cache, and what a long context does not buy

The decision this supports is recorded in
[ADR 0010](../adr/0010-memory-is-a-small-window-over-a-pinned-carry-forward.md). This document holds
the evidence: what memory has to satisfy, how the mechanisms compare against those requirements, what
the chat provider's prompt cache actually does (and why it does not rescue this prompt), and what the
long-context literature says about sending more of everything.

## What memory has to satisfy

| Requirement | Source | Consequence |
| --- | --- | --- |
| A follow-up's cited chunk must be eligible in *this* Answer's Evidence set | Define citation verification (#7), Define the answer confidence score (#8) | prior citations must be *re-admitted*, so the mechanism carries chunk ids regardless of what else it does |
| Citations resolve to document chunks only, never to an earlier Answer | #7, #8 | past turns are prompt context, never a citable source |
| Confidence is per Answer, never averaged across a Conversation | #8, ADR 0004 | memory cannot borrow last turn's band, and a follow-up is scored on its own evidence |
| The correction case: a superseded value must not return | Design the eval harness (#10) | memory must not keep both a value and its correction as peers |
| Verification runs on canonical text from Postgres within 5 s | #7, ADR 0003 | carried chunks must be hydratable without the vector store |
| `clone → env → docker compose up`, no extra service | map charting | no memory daemon, no second vector space by default |
| The Conversation holds no derived state | `GLOSSARY.md` | a persisted summary or turn table reopens a settled definition |
| Admission prices the prompt before the call | Settle cost tracking (#13), ADR 0008 | memory's token cost must be bounded and estimable before assembly |

## The mechanisms compared

| | Verbatim window | Rolling summary | Retrieval over history |
| --- | --- | --- | --- |
| Extra calls | none | one per N turns, plus its own trigger | one embed per turn (local, zero-priced) |
| Extra storage | none — reads `answers`, `citations` | a summary row, its version, its trigger state | a turn-embedding collection, its lifecycle, its reindex rule |
| Exact wording preserved | yes | no — the correction case loses the text it is about | yes, but only for turns that happen to be retrieved |
| What a gate can assert offline | everything: assembly, membership, span, confidence | the summary's content (a model output) | a second ranking, in an incomparable space |
| Failure mode | long conversations lose distant referents | lossy paraphrase silently replaces the record, and stale summaries persist past their corrections | retrieved past text competes with document evidence and cannot be cited |
| Effect on the prompt prefix | grows append-only | **rewritten** on every refresh | append-only, with a volatile block inside |

The window's weakness — distant referents drop out — is the one weakness the pinned carry-forward
already addresses for the case that matters, because the *document* a referent came from is what a
follow-up needs to cite, and that arrives through the tier rather than through prose.

## What DeepSeek's prompt cache does, and does not, do for a conversation

Context caching is **on by default**, needs no header or `cache_control`, and is keyed on the leading
tokens of the request: "only requests with identical prefixes (starting from the 0th token) will be
considered duplicates. Partial matches in the middle of the input will not trigger a cache hit."
Multi-turn conversation is documented as one of its two canonical use cases. The current guide adds a
stricter rule than a shared prefix: cached prefixes are persisted as independent **cache prefix units**,
and a later request hits only by fully matching a persisted unit. Units are persisted at the **end of
the user input** and the **end of the model output** of each request, by common-prefix detection across
requests, and at fixed token intervals for long inputs. Retention is "a few hours to a few days", best
effort — not a guarantee.

Two consequences for this product, and one of them is unwelcome:

1. **The constant instruction block is cached.** It is the same bytes at the start of every request, so
   it is a common prefix across requests and hits the cheap rate. This is real money and requires no
   work beyond keeping the block genuinely constant and first.
2. **Per-turn conversation history mostly will not be.** The cache unit persisted for turn *N* ends at
   the end of turn *N*'s user input — which contains turn *N*'s evidence block. Turn *N+1*'s prefix is
   the same instructions and history, then a *different* evidence block, so the two diverge at the
   evidence, at exactly the boundary memory would have to sit. The naive layout therefore yields hits
   on the instruction block and misses on everything after it. A pinned carry-forward makes a turn's
   prefix *less* stable, not more, since the evidence block changes by construction every turn.

   This does not reverse the decision — the window is chosen for exactness and for the correction case,
   and it is bounded regardless — but it does mean the honest cost model is the **cache-miss** rate,
   which is the rate ADR 0008's admission check already prices at. Do not book cache savings against
   the History window in any estimate until a real run shows a hit. If a future layout does earn hits
   (`system → history → evidence → question`, evidence last), the saving shows up in
   `model_calls.prompt_cache_hit_tokens` and nowhere else.
3. **A rolling summary is strictly worse on this axis**, because refreshing the summary rewrites the
   prefix it sits in, converting a cacheable common prefix into a guaranteed miss every time it changes.

## What the long-context literature says about a larger window

Liu et al., *Lost in the Middle: How Language Models Use Long Contexts* (TACL 2024), measures exactly
the situation a growing conversation creates:

- Performance is **highest when the relevant information is at the beginning or end** of the input and
  **degrades significantly when it is in the middle**, "even for explicitly long-context models". So
  *where* the History window sits in the prompt is a real design variable, not an aesthetic one — it
  belongs to context assembly.
- In open-domain QA, "model performance saturates long before retriever recall saturates": going from
  20 to 50 retrieved documents improved accuracy by roughly 1.5% and 1.0% for the two models tested.
  Adding context has sharply diminishing returns once the answer is present — which is the empirical
  case for a small window, and a caution against treating a 1M-token context as licence to send
  everything.

Neither result is a measurement of *this* system; both argue against assuming that more history is
better history.

## Token arithmetic

| Component | Tokens | At $0.15/M off-peak | At $0.30/M peak |
| --- | --- | --- | --- |
| Instruction block | ~600 | $0.00009 | $0.00018 |
| Evidence, ≤20 chunks × ~400 | ~8,000 | $0.00120 | $0.00240 |
| Question, ≤4,000 chars | ≤1,000 | $0.00015 | $0.00030 |
| History window, optional | ≤2,000 | $0.00030 | $0.00060 |
| Mandatory most-recent exchange | ~400 | $0.00006 | $0.00012 |
| **Prompt total, typical** | **~12,000** | **$0.0018** | **$0.0036** |

The window is about 17% of prompt tokens: a real but bounded uplift, which is why the account's $5
monthly budget still buys well over a thousand turns. The mandatory most-recent exchange is priced as
its own allowance so that a single long answer cannot push the optional window over its limit.

## What this survey does not settle

- **Where the History window and the Evidence set sit relative to each other**, and what receives the
  instruction block's tail — context assembly's ticket.
- **Whether a reranker joins the seams** — depends on the token budget context assembly settles.
- **Whether a summarising or history-retrieval arm beats the window** — an eval outcome, gated by the
  multi-turn items, not a decision to take now.
- **The copy for a miss** — belongs to the UI scope ticket and the fog that follows it.

## Unverified

- **No measurement of this window.** 2,000 tokens, four exchanges, six carried chunks and a 200-token
  rewrite ceiling are launch defaults, not findings; the multi-turn items are what will move them.
- **The prompt-cache analysis above is reasoning from documented mechanics**, not from a run of our
  layout. Whether DeepSeek persists a unit that happens to match our first ~600 tokens is expected but
  unobserved; `prompt_cache_hit_tokens` will say.
- **The rewrite call's latency** is unmeasured. It sits in front of retrieval, so it is squarely on the
  time-to-first-token path; a slow `deepseek-flash` turn makes every follow-up slow before it begins.
  That is why its deadline — `REWRITE_DEADLINE_SECONDS = 5`, bounding the whole step rather than one
  attempt (ADR 0010) — is a judgement and not a measured ceiling.
- **The carry cap of six** is a guess at how many chunks a follow-up plausibly still rests on.
- **`deepseek-flash`'s willingness to resolve a pronoun from a four-exchange window** is untested; the
  nightly rewrite-fidelity arm is the instrument, and it does not exist yet.

## Sources

- [DeepSeek: Context Caching](https://api-docs.deepseek.com/guides/kv_cache) — default-on,
  prefix-keyed, cache prefix units and their persistence rules.
- [DeepSeek: Context Caching on Disk announcement](https://www.deepseek.com/en/news/context-caching) —
  identical-prefix requirement, multi-turn conversation as a canonical case.
- Liu et al., *Lost in the Middle: How Language Models Use Long Contexts*, TACL 12 (2024) —
  [ACL Anthology](https://aclanthology.org/2024.tacl-1.9) · [arXiv:2307.03172](https://arxiv.org/abs/2307.03172)
- Rate card and peak-window data: [`config/pricing.toml`](../research/cost-and-pricing.md) as recorded
  by ADR 0008.
