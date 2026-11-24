# Gate determinism exactly, and generation statistically

**Status:** accepted
**Date:** 2026-11-24

The eval harness has two modes split by **determinism**, not by cost. Retrieval metrics, the terminal span gate and the confidence arithmetic are deterministic given a fixed index and a pinned model, so the PR gate runs them **exactly** against committed floors, offline, from a precomputed index artifact that includes the fixed query vectors. Everything the generator writes is measured **nightly**, live, with tolerance bands, because DeepSeek is not deterministic even at temperature 0 and a build gate that flickers is a gate people turn off.

"What production grade" means in numbers is thus split along the line the architecture already drew: the parts that are evidence about retrieval and support are asserted, and the part that is a sample from a model is trended. **Gold labels are spans** — `{document, page ordinal, section path, quote}` — resolved at run time to the chunks of whatever index is currently in force, so a chunking change reindexes the labels instead of invalidating them. The harness is **in-repo** (`evals/`, a CLI, a committed baseline) rather than Ragas, DeepEval or TruLens, because three of its four metric families are computed from data no framework models: evidence-set membership, span offsets, and persisted verdicts. And the two constants the product ships provisionally — HHEM's `0.70 / 0.50` support thresholds and confidence's `0.85 / 0.55` band cut-points — are changed only by `evals fit`, which emits a report and a diff, never inside a gate run.

## Considered Options

- **Live generation on every PR, small set** — simplest, and it puts model nondeterminism directly on the build gate; a red build then means "or the model wobbled".
- **Record/replay fixtures for the PR gate** — fully offline and deterministic, but a fixture is keyed by its prompt, so any PR that changes retrieval or prompt assembly invalidates the fixtures it needs. Kept only for unit-level regression of prompt assembly and response parsing.
- **Ragas, DeepEval, TruLens or Phoenix as the runner** — real judge metrics and reporting, and no concept of an evidence set, a quote gate, or a support share; adopting one means reimplementing the differentiated half inside its plugin layer.
- **Gold labels as chunk ids** — direct, and invalidated by every chunking change, which is exactly what the harness exists to sweep.
- **Gold labels at document granularity** — survives everything and cannot rank chunks, so it cannot tune fusion depth, chunk size or overlap.
- **Ingesting the corpus on every PR** — exercises the real pipeline and costs minutes of CPU Docling, which does not fit an 8-minute gate.
- **A committed Qdrant snapshot** — fast, and rots silently with no second path to disagree with it.
- **An LLM judge on the PR gate** — the best available correctness signal, at a network round trip, a live key and a same-family grader inside a build decision.
- **Absolute floors only, or regression guards only** — the first lets quality erode a step at a time, the second ratifies whatever the last run shipped.

## Consequences

- The PR gate proves **retrieval, the span gate and the confidence arithmetic**, plus a 12-question generation smoke. It does not prove generation quality: a prompt change can regress answers and be caught only by the nightly run. Prompt-touching PRs therefore run the full generation set locally before review, and carry the scoreboard diff.
- Tolerances are **measured**, not chosen: twice the spread of three identical baseline runs, stored in the baseline file beside each metric, so loosening one is a visible diff.
- The eval index artifact binds to `chunk_config_hash` **and** the embedding identity, because it contains query vectors. A change to either is an artifact miss that takes the build path — never a silent evaluation against a stale index.
- Nightly always re-ingests from the PDFs, which is what keeps the fast path honest: the artifact and a real ingestion must produce the same index or the nightly run says so.
- Human labels are one annotator's, with a blind 20 % re-label and a published κ against the judge as the controls. `verdict κ ≥ 0.60` and `high-band precision ≥ 0.85` are therefore statements about agreement with a person, not about truth.
- The dataset is **versioned semver**, and rebaselining is a reviewed diff written by `evals rebaseline`. A metric improving by more than `0.05` with no explanation is flagged, because that is the signature of label leakage or a broken gold resolver.
- Confidence gate **G4** and the band cut-points become fittable only because the corpus ships single-document and two-document tenant subsets; without them the harness cannot see the case that gate special-cases.
- Cost is not the binding constraint: an 80-question nightly run plus judge is well under `$0.25` at `deepseek-flash` off-peak rates, which is why the nightly schedule sits outside DeepSeek's peak windows rather than being economised.
- Conversation memory is **not measurable by dataset v1**, which is single-turn; that lands as a requirement on [Decide conversation memory semantics](https://github.com/mobley-trent/genweaver/issues/17) rather than being discovered when someone tries to regress it.
