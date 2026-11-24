# Own the model seams, select models by environment, and fail closed

**Status:** accepted
**Date:** 2026-11-24

Every model call in genweaver goes through one of three seams — **chat**, **embeddings** and, since
[ADR 0003](0003-verified-citations-with-a-local-verifier.md), the **verifier**. They are ours: one
Python `Protocol` each, an OpenAI-compatible adapter as the only chat and embedding implementation at
launch, and a code-level registry of model facts. The deployment selects a provider and model by
environment variable; no database row decides which model answers. Retries are bounded and classed,
there is no cross-provider failover, and a request that has begun streaming is never retried.

The deciding constraint is the same one that made the verifier local and the ingest queue a Postgres
table: everything a reader would need to trust an answer has to be a fact this repo owns. An answer's
provenance names the provider, the model, its mode and its parameters; an eval arm pins the same
values. A library whose product is *normalising* those differences away is therefore the wrong
foundation, however many providers it offers. DeepSeek is the only live chat key and a TEI sidecar
serves embeddings at an OpenAI-shaped `/v1/embeddings` — the two providers this project actually has
fit one adapter, so the abstraction we need is small.

LiteLLM was the serious alternative and is rejected on evidence rather than taste: DeepSeek V4's
`reasoning_effort` was silently discarded by its mapping for five months (issue #27439, open
2026-05-08 through 2026-10-25, fix PR #38736), while the direct API rejects an invalid effort with
422 — so a request that looked pinned upstream was not. Its `reasoning_content` handling also needed
patching for multi-turn DeepSeek conversations (#26395), which is every conversation here. That is a
property of placing vendor-specific mappings downstream of us. The opinion is not that LiteLLM is
bad; it is that this project's differentiator is the exact request and the honest record of it.

## Shape

```python
# app/providers/base.py — three seams, one warm-up convention
class ChatProvider(Protocol):
    identity: ModelIdentity                     # provider, model, known revision
    def complete(self, req: ChatRequest) -> ChatResult: ...
    def stream(self, req: ChatRequest) -> Iterator[ChatEvent]: ...   # Token…, Usage, Done
    def ready(self) -> bool: ...

class EmbeddingProvider(Protocol):
    identity: EmbeddingIdentity                 # provider, model, dims
    max_input_tokens: int
    def embed(self, texts: Sequence[str]) -> list[list[float]]: ...
    def ready(self) -> bool: ...

class Verifier(Protocol):
    identity: VerifierIdentity                  # checkpoint name, pinned revision
    def score(self, pairs: Sequence[tuple[str, str]]) -> list[float]: ...
    def warm(self) -> None: ...
    def ready(self) -> bool: ...
```

`ChatRequest` carries `messages`, `temperature`, `max_tokens`, `thinking` (`bool | None`), `seed`
(where the provider supports it), `response_format` and a deadline. `ChatResult` carries the text,
provider-reported `usage`, `finish_reason`, the model string the provider echoed, and latency. A
streaming call emits deltas and a terminal usage event — DeepSeek reports usage on the last content
chunk, so the adapter normalises that into the event rather than letting pipeline code know.

The registry is a frozen table, not provider code:

```python
# app/providers/registry.py
@dataclass(frozen=True)
class ChatModelFacts:
    context_window: int
    max_output: int
    thinking_default: bool
    structured: Literal["json_object", "json_schema", "none"]
    price_key: str
    known_revision: str | None

CHAT_MODELS: dict[tuple[str, str], ChatModelFacts] = {
    ("deepseek", "deepseek-flash"): ChatModelFacts(1_000_000, 393_216, True, "json_object",
                                                   "deepseek-flash", "V4.1-Flash-1017"),
    ("deepseek", "deepseek-v4-pro"): ChatModelFacts(1_000_000, 393_216, True, "json_object",
                                                    "deepseek-v4-pro", "V4-Pro-0813"),
}

EMBEDDING_MODELS: dict[tuple[str, str, int], EmbeddingModelFacts] = {
    ("tei", "Qwen/Qwen3-Embedding-0.6B", 1024): EmbeddingModelFacts(max_input_tokens=32_768,
                                                                    price_key="local-cpu"),
}
```

Configuration is environmental and complete at boot:

```
CHAT_PROVIDER=deepseek          CHAT_MODEL=deepseek-flash
CHAT_BASE_URL=https://api.deepseek.com   CHAT_API_KEY=…
CHAT_THINKING=off               CHAT_TEMPERATURE=0.2
EMBEDDING_PROVIDER=tei          EMBEDDING_MODEL=Qwen/Qwen3-Embedding-0.6B
EMBEDDING_DIMS=1024             EMBEDDING_BASE_URL=http://tei/v1
VERIFIER_MODEL=hhem-2.1-open    VERIFIER_REVISION=<pinned sha>
```

Adding a provider is therefore one adapter module, one registry entry and one env block — no change
to retrieval, prompt assembly or verification code. With the OpenAI-compatible adapter already in
place, a provider with a non-OpenAI shape is the only case that writes new transport code, which is
exactly the case that needs it.

## Failure semantics

| Class | Behaviour |
| --- | --- |
| Connect timeout, 429, 5xx | Up to 3 attempts with jittered 1 s / 4 s backoff, honouring `Retry-After` up to 30 s — **only before the first token** |
| 400 / 401 / 403 / 404 / 422 | No retry; the call fails with a typed error |
| Stream broken after the first token | No retry and no silent restart: the client has already rendered text. The stream terminates with an error event; what is persisted for a broken answer belongs to the API contract (#14) |
| Verifier unavailable or over its 5 s budget | `unchecked`, per [ADR 0003](0003-verified-citations-with-a-local-verifier.md) — never `failed` |
| Embedding call fails | Surfaces to the ingestion job, whose own retry policy (#5: 3 attempts, 30 s / 2 m / 8 m) owns recovery |
| Deadlines | Chat request 120 s, first token 30 s, embedding call 60 s |

**The numbers above are launch defaults, not findings.** Three attempts, the 1 s / 4 s jitter, the 30 s `Retry-After` ceiling and the 120 s / 30 s / 60 s deadlines were chosen by judgement at spec time: nothing has been measured, because there is no system yet to measure. They are provisional in exactly the sense [ADR 0006](0006-gate-determinism-exactly-and-generation-statistically.md) uses for HHEM's `0.70 / 0.50` and confidence's `0.85 / 0.55` — named constants with documented defaults, **not** per-call arguments and **not** per-deployment environment knobs, moved only by a reviewed diff that cites the measurement that moved them: a latency or error histogram from the observability the map defers, a run of the eval harness, or a recorded incident. A retry count raised because a test was flaky, or a deadline shortened because one call felt slow, is the change this paragraph forbids.

There is deliberately no fallback to a second provider. An automatic switch would mean the answer's
provenance names a model that may not be the one that produced it, and every eval arm would silently
mix models at the moment a provider wobbles. A deployment that wants a different provider sets one
and restarts, which is a visible, recorded change.

## Provenance

| Artifact | Recorded |
| --- | --- |
| Answer | chat provider, model, echoed model string, `known_revision` at run time, thinking mode, temperature, parameters hash, prompt version |
| Chunk | embedding identity `(provider, model, dims)`, model revision, alongside the existing `chunker_version` and `chunk_config_hash` |
| Verdict | verifier name, pinned checkpoint revision, and the threshold set in force |

This is what makes "the answers got worse last Tuesday" answerable: the row says which model, in
which mode, under which prompt, verified by which checkpoint.

## Considered Options

- **LiteLLM** — many providers, a maintained price map, and a normalisation layer sitting between us
  and the exact request we pin; its DeepSeek V4 mapping was wrong for five months and its
  multi-turn `reasoning_content` handling needed patches.
- **OpenAI SDK everywhere with a `base_url` swap** — least code, works today for DeepSeek and TEI, and
  makes the SDK the seam: the first non-OpenAI provider leaks into pipeline code, and SDK versioning
  governs our request shape by default.
- **One shared protocol with optional methods** — one type to learn, at the cost of every
  implementation carrying the others' concerns and the judge-unreachable rule becoming a runtime check.
- **A database-backed model registry, switchable at runtime** — an admin can change models without a
  restart; costs a migration, an admin surface, cache invalidation, and makes "what produced this
  answer" depend on a mutable row instead of a deployment fact.
- **Automatic cross-provider failover** — higher availability during a provider outage, at the cost of
  answers whose quality changed silently and eval runs that mix models.
- **Entry-point plugin discovery for providers** — adding a provider without editing the repo; buys
  configurability the project does not need, since a new provider needs an adapter anyway.

## Consequences

- We own roughly 250 lines of adapter, registry and retry policy. In exchange every request we pin is
  the request that leaves the process, and every provenance row is true.
- Chat and embedding providers are chosen per deployment; eval arms override the same settings
  in-process rather than mutating the database, so a run is reproducible from its config.
- A DeepSeek outage is a visible outage. That is accepted: the honest failure is worth more than an
  invisible model substitution in a project whose claim is verified citation.
- The registry carries a `price_key`, not prices; [Settle cost tracking](https://github.com/mobley-trent/genweaver/issues/13)
  owns the table, the window and the enforcement.
- The verifier is absent from the provider registry, so no environment variable can point verification
  at the generator's model family. The judge lives under `evals/` and imports the chat adapter
  directly, never through the product's registry.
- No `seed` on DeepSeek means run-to-run variation is structural; the nightly tolerance bands of
  ADR 0006 absorb it, and the PR gate never calls the model.
- Provenance now records a **prompt version**, which forces context assembly to define what a prompt
  version is and when it bumps. That is fog on the map, not a decision this ticket could make.
- The registry's `known_revision` is maintained by hand, because providers roll versions under a stable name. Noticing that a revision moved is an observability concern, added to the map's fog rather than settled here.
- The retry budget, its backoff and the three deadlines have **no measurement behind them**. Until the observability fog produces latency and error distributions, a change to any of them is a change without evidence, and tuning one to make a local run pass is the failure mode the paragraph above names.

See [`docs/research/provider-abstraction.md`](../research/provider-abstraction.md) for the request
shapes, the provider comparison and the sources this rests on.
