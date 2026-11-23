# Verify citations in two layers, with a local verifier rather than the generating model

**Status:** accepted

Every claim sentence in an answer must carry at least one **citation**, and every citation is verified before it is shown as one. Verification is two checks in a fixed order. The first is a **span gate**: the chunk the citation points at must be in the answer's evidence set, and the quoted span the generator attributed to it must be locatable in that chunk's canonical markdown. The second is an **entailment check**: a local factual-consistency model scores whether the cited chunk supports the claim sentence. The span gate is terminal — a quote that cannot be found voids that citation, and nothing downstream can rescue it.

The two checks are not interchangeable. A span check answers "is the quote real" in microseconds and is blind to a real quote that does not support the sentence; an entailment score answers "does this source support this claim" and is blind to a quote the model invented and then faithfully reproduced for its own checker's benefit. A single-mechanism design therefore fails on exactly one of the two failure modes this project claims to catch.

**Why a local verifier and not the better judge.** Refereed head-to-head work finds an LLM judge agrees with human citation judgements far better than an NLI checker does — LongCite reports κ ≈ 0.54–0.66 for GPT-4o against 0.15–0.25 for a T5-XXL NLI on statement-level citation support. That evidence is accepted, and it is why the judge ships as an eval-harness arm. It is not the product verifier, for three reasons that outrank the agreement gap. A judge drawn from the same model family as the generator is grading its own homework, and "verified citations" is the one claim this project cannot afford to make cheaply. A hosted judge makes verification cost money per answer and need an API key, on a stack whose promise is `docker compose up` with a local generator. And a judge puts a network round trip on the answer path — from a model that reasons by default before it answers, so tens of seconds unless thinking is explicitly disabled — where verification is meant to be a cheap second opinion.

The verifier is **HHEM-2.1-Open** (Apache-2.0, ~110M parameters, <600 MB fp32), pinned by revision, scoring each claim against its cited chunk in one batched call per answer. MiniCheck-RoBERTa-L (MIT) sits behind the same seam as the alternate checkpoint, and the judge is importable by the eval harness only — there is deliberately **no user-facing configuration** that would let a deployment swap its verifier for the family that wrote the answer.

**What is verified against.** The premise is the canonical markdown slice fetched from Postgres at the chunk's character offsets, not the `text` string that came back in the vector store's payload. The two are byte-identical by ingestion's contract, so they agree unless something has broken — which is the case that matters. A citation should be checked against the document, not against the retrieval cache that surfaced it. A generator's quote is used only as a **locator**; the span displayed to the user is the canonical text it matched, never the model's retyping.

Five states follow, and keeping "not checked" separate from "checked and failed" is the point of the last one: **verified** (span located, support ≥ 0.70), **partial** (span located, support in 0.50–0.70), **failed** (span not located, chunk outside the evidence set, or support < 0.50), **uncited** (no citation at all), **unchecked** (verification did not run — the verifier was unavailable or over budget). A failure is never also a silence: the citation is marked and struck, the sentence stays, and no regeneration runs behind the user's back.

## Considered Options

- **Verbatim span check alone** — free and deterministic, but it passes any real quote however irrelevant and fails every faithful paraphrase. It is a gate here, not a verdict.
- **LLM judge as the verifier** — the best human agreement available, at a per-answer cost, an API-key dependency, a blocking round trip, and a verifier that shares a family with what it verifies.
- **Local NLI cross-encoder (`nli-deberta-v3-xsmall`, 71M)** — smallest and fastest, but uncalibrated, single-sentence-trained and lexical-overlap-prone: 28–33 % of its errors are entity swaps and dropped negations, which is the failure a verification feature exists to catch.
- **`roberta-large-mnli` or a reranker** — the first is a MiniCheck-sized model with no RAG-specific advantage; the second scores topical relevance rather than support, and would rate a negated claim highly.
- **Dropping a failed citation while keeping its sentence** — makes an unsupported claim indistinguishable from prose. Rejected outright.
- **Automatic regeneration on failure** — doubles cost and latency on the worst path and launders the failure into a second answer checked by the same checker that just failed.

## Consequences

- The answer is a **structured artifact**: claim ids with citation attachments, segmented by the system rather than by the generator's own markers. An uncited claim is visible, so citing less cannot raise the verification score.
- Verification runs **after** the answer completes, in one batched call, bound to the persisted answer rather than to the HTTP connection. Tokens stream first; verdicts arrive as a terminal event. A disconnect costs delivery, not the result.
- Verdicts are **stored rows** carrying the raw score and the thresholds applied at write time, so re-deriving them after a threshold change is an operation, not a re-run.
- Support thresholds (0.70 verified, 0.50 partial) are **knobs fitted by the eval harness**, not calibrated constants. Every candidate model's published calibration is a vendor claim validated on summarisation data.
- The verifier is a **third provider seam**, independent of chat and embeddings, which is what lets the eval harness swap in MiniCheck or the judge without touching the answer path.
- Citation recall and precision become measurable against human labels, and the local verifier carries a published accuracy ceiling: ~74 balanced accuracy on AggreFact-SOTA is its own bar, not GPT-4's.
- A broken verifier degrades every citation to **unchecked** and logs it against the answer. There is no path on which an unchecked citation is presented as verified.
