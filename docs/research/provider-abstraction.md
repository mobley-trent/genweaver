# Provider abstraction: the seams, the libraries, and the request shapes

The decision this supports is recorded in
[ADR 0007](../adr/0007-own-the-model-seams-and-fail-closed.md). This document holds the evidence:
what the seams must carry, the exact provider request shapes we must control, and how the candidate
routes compare. The ADR links here rather than restating the survey.

## What the seams must carry

| Requirement | Source | Consequence for the seam |
| --- | --- | --- |
| `clone → env → docker compose up` produces a working app | map charting | provider and model chosen by environment; no runtime admin surface needed to boot |
| Chat and embeddings come from different vendors — DeepSeek exposes no embeddings endpoint | Define the embedding provider (#2) | two seams with separate configuration, not one "model provider" setting |
| The verifier is local, offline, deterministic, and has `warm()` / `ready()` | Define citation verification (#7), ADR 0003 | a third protocol with a lifecycle the chat and embedding calls do not have |
| The judge must be unreachable from the product | #7, Design the eval harness (#10) | the judge is importable by `evals/` only; it is absent from the product's provider registry |
| Per-call `model`, `temperature`, `seed` where supported, thinking mode, `response_format` | #10 | a request object per call, never ambient module state |
| Usage reported per call | Settle cost tracking (#13, open) | the seam surfaces provider-reported usage; it does not compute prices |
| Embedding identity names the collection | Decide the Qdrant collection layout (#6) | the embeddings seam exposes `(provider, model, dims)`, not just a vector |
| Answers stream | Set the API surface (#14, open) | the chat seam streams deltas and reports usage at the end, not only in one shot |

## Request shapes we must control

### DeepSeek chat

| Field | Behaviour | Source |
| --- | --- | --- |
| Base URL | `https://api.deepseek.com` (OpenAI format, no `/v1`; `/anthropic` is a separate format) | Models & Pricing |
| Models | `deepseek-flash` (served version `DeepSeek-V4.1-Flash-1017`), `deepseek-v4-pro` (`DeepSeek-V4-Pro-0813`) | Models & Pricing |
| Context / output | 1M context, up to 384K output tokens | Models & Pricing |
| Thinking toggle | `{"thinking": {"type": "enabled" \| "disabled"}}`; **enabled by default**; with the OpenAI SDK it must ride in `extra_body` | Thinking Mode |
| Thinking effort | `reasoning_effort`: `none` disables; `low` / `high` / `max` select; default `high` | Thinking Mode |
| Temperature | 0–2, default 1; **no effect while thinking is on** | Chat Completions |
| `top_p` | Fixed at 1.0 in non-thinking mode (value ignored); 0.95–1.0 effective in thinking mode | Chat Completions |
| `seed` | Not in the Chat Completions schema | Chat Completions |
| `response_format` | `{"type": "json_object"}` only; no strict schema; the prompt must contain the word "json" | Chat Completions, JSON Output |
| Streaming usage | No separate usage-only chunk: statistics ride the last content chunk, whose `choices` holds one entry with no new content and a non-null `finish_reason` | Chat Completions |
| Default `max_tokens` | 8K non-thinking, 64K thinking (128K at `max` effort) | Chat Completions |

Two consequences follow. Pinning temperature does nothing while thinking is on, so an eval arm that
wants sampling control must also disable thinking; and with no `seed`, run-to-run variation is
structural, which is why [ADR 0006](../adr/0006-gate-determinism-exactly-and-generation-statistically.md)
gates generation statistically and the PR gate never calls the model at all.

### TEI embeddings

| Field | Behaviour | Source |
| --- | --- | --- |
| Model | `Qwen/Qwen3-Embedding-0.6B`, Apache-2.0, 1024 dimensions, 32,768-token inputs | model card; embedding-provider research |
| Serving | `text-embeddings-inference` CPU image; OpenAI-compatible `/v1/embeddings` | TEI docs |
| Cost | Local CPU/RAM, no per-token price; metered for display, priced at zero | ADR 0007, #13 pending |

Because TEI speaks the OpenAI embedding shape, the same adapter that calls a hosted embeddings API
calls the local sidecar: only `base_url` and the API key differ.

## Routes compared

### Own thin protocols with an OpenAI-compatible adapter

One `Protocol` per seam; one adapter class per transport. DeepSeek chat and TEI embeddings share the
`openai_compat` implementation because both are OpenAI-shaped, with provider-specific knobs
(`extra_body` for DeepSeek thinking) confined to the adapter.

- **For:** total control of the request we pin, of usage, and of what is written into provenance;
  no dependency between the product's behaviour and a third party's vendor-parameter mapping; the
  "judge is unreachable" rule stays an import boundary rather than a runtime check.
- **Against:** we write and maintain the adapters (roughly 250 lines for two), and a provider with a
  non-OpenAI shape (Anthropic messages, Cohere rerank) needs a real adapter rather than a flag.

### LiteLLM

One dependency, an OpenAI-shaped interface over 100+ providers, and a price/context catalogue.

- **For:** adding a provider is configuration; the price map is maintained upstream.
- **Against:** its value is normalisation, and normalisation is what we must not have — the answer's
  provenance names the model *and its mode*, and the eval harness pins the exact request. The
  DeepSeek V4 mapping we depend on was wrong for five months:

  | Date | Event |
  | --- | --- |
  | 2026-05-08 | Issue #27439: `reasoning_effort` is discarded and mapped to `thinking: {"type": "enabled"}` regardless of the value requested |
  | 2026-05-13 | PR #27829 proposes the correct mapping; closed 2026-08-16 without merging |
  | 2026-09-20 | Confirmed still present on 1.99.0: an invalid `reasoning_effort` sent through LiteLLM returns 200 while the same request direct to DeepSeek returns 422 |
  | 2026-10-25 | Fixed upstream by PR #38736 |

  That is a stability property of the layer, not a one-off: the parameter is vendor-specific, and
  the mapping lives downstream of us. A second wrinkle is structural — LiteLLM's own
  `reasoning_content` handling needed patches for multi-turn DeepSeek V4 conversations (#26395),
  which is the shape every conversation in this product has.

### OpenAI SDK everywhere, `base_url` swap

- **For:** least code; genuinely sufficient for DeepSeek and TEI today.
- **Against:** the seam is the SDK's surface, so the first non-OpenAI provider (or a provider whose
  auth, streaming or usage differs) leaks into pipeline code; the SDK's own versioning then governs
  our request shape by default rather than deliberately.

### One shared protocol for all three seams

A single base class with `chat()`, `embed()` and `verify()` methods.

- **For:** one type, one registry.
- **Against:** chat streams tokens over a network, embeddings batch vectors, and the verifier answers
  a closed question about two strings on CPU with a load-time warm-up. A shared protocol makes each
  implementation carry the others' concerns, and it turns "the judge cannot be reached from the
  product" into a check that config can defeat.

## What this survey does not settle

- **The price table's shape** — belongs to [Settle cost tracking](https://github.com/mobley-trent/genweaver/issues/13).
  The registry carries a `price_key`; it does not carry prices.
- **Where API keys live in the compose file** — belongs to
  [Specify Docker Compose deployment](https://github.com/mobley-trent/genweaver/issues/15).
- **What a prompt version is** — the seam records one, but its definition belongs to context
  assembly, still fog on the map.
- **Whether a reranker joins the seam set** — depends on context assembly and the token budget.

## Unverified

- Whether DeepSeek's `model` field in a response echoes the served revision (`DeepSeek-V4.1-Flash-1017`)
  or only the alias. The docs state that versions change under a stable name; the response shape is
  documented as a plain string. The registry therefore keeps an operator-maintained `known_revision`.
- Whether TEI's OpenAI-compatible `/v1/embeddings` response includes a `usage` block with token
  counts. If it does not, embedding usage must be estimated from the tokenizer; #13 owns that.
- LiteLLM's current (post-#38736) behaviour for `thinking` toggling and multi-turn `reasoning_content`;
  the timeline above is about the mapping, not an audit of today's release.

## Sources

- [DeepSeek Chat Completions API](https://api-docs.deepseek.com/api/create-chat-completion) ·
  [Thinking Mode](https://api-docs.deepseek.com/guides/thinking_mode) ·
  [Models & Pricing](https://api-docs.deepseek.com/quick_start/pricing) ·
  [JSON Output](https://api-docs.deepseek.com/guides/json_mode)
- LiteLLM: [issue #27439](https://github.com/BerriAI/litellm/issues/27439) ·
  [PR #27829](https://github.com/BerriAI/litellm/pull/27829) ·
  [issue #26395](https://github.com/BerriAI/litellm/issues/26395) ·
  [DeepSeek provider docs](https://docs.litellm.ai/docs/providers/deepseek) ·
  [embedding support](https://docs.litellm.ai/docs/embedding/supported_embedding)
- [Qwen3-Embedding-0.6B](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B) ·
  [TEI](https://huggingface.co/docs/text-embeddings-inference/supported_models)
