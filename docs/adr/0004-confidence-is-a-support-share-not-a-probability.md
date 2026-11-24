# Confidence is a support share, not a probability

**Status:** accepted

The confidence shown with an answer is a **support share**: the fraction of the answer's claims that its own verified sources back. Each claim contributes 1 if `verified`, 0.5 if `partial`, 0 if `failed` or `uncited`; claims that are `unchecked` do not produce a score at all. That base is then passed under a ladder of **gate ceilings** that can only lower the band, never raise the number, and the result is presented as one of three bands — high, medium, low — alongside the arithmetic that produced it.

The obvious alternative, and the one the product name invites, is a calibrated probability that the answer is correct. It is rejected on honesty rather than on difficulty. A probability claim needs a measuring set spanning many queries, documents and failure modes, and an answer-level ground truth that says a whole response is right or wrong; the project has neither, and will not for a long time. Support share needs only what verification already persists — per-claim verdicts — so it is exactly as good as the verifier, no better, and it says so: *this much of what I said is backed by the documents I cited*, never *this much of what I said is true*.

**Nothing but verification enters the number.** Model self-assessment is out: verbalized confidence is uncalibrated without a measuring set, and a generator scoring its own grounding is the self-grading failure [ADR 0003](./0003-verified-citations-with-a-local-verifier.md) already refuses. Retrieval similarity is out for a subtler reason: the fused ranking is **ordinal, not a similarity** (see [ADR 0002](./0002-tenant-partitioned-hybrid-retrieval-without-sparse-vectors.md)), and raw dense cosine is not comparable across embedding models, chunk lengths or query shapes, so any normalisation of it into a 0–1 confidence is invented at the seam. Branch ranks for cited chunks are persisted as **diagnostics** instead, so the eval harness can test whether retrieval agreement predicts support — without letting a good lexical match inflate confidence on a claim whose entailment failed.

The gate ladder exists because a linear mean over claims is actively misleading in the one case that matters. Four of five claims verified reads as 0.8, and a single fabricated quote would otherwise sit at "high". So: any `failed` claim ceilings the band at medium, an answering majority of `uncited` claims ceilings it at low, and "high" additionally requires at least one `verified` claim and a verified share of at least two thirds — an answer made entirely of `partial` citations is a real source weakly supporting, and should never present as strongly grounded however many weak sources accumulate. Corroboration is the weakest of these gates and the one most likely to be fitted away: it also demands two distinct documents behind the verified claims, which means a single-document library bands medium on a perfect answer.

## Considered Options

- **Calibrated probability of correctness** — the strongest promise, unsupportable without an answer-level ground-truth set, and misleading in the meantime.
- **Blend of verification, retrieval and self-assessment** — richer signal, but each term is either unnormalisable (cosine), ordinal (fused rank) or uncalibrated (self-report), and the blend cannot be explained when it moves.
- **Linear mean with no ceilings** — simple, and lets one struck citation ride at high confidence.
- **Minimum claim state as the score** — maximally conservative, and blind to the difference between one bad claim out of ten and five out of ten.
- **Treating `unchecked` as 0.5 or as 0** — invents medium confidence or a false accusation from a verifier outage. `unchecked` voids the number and is shown as "support not checked", never as a low band.
- **Averaging confidence across a conversation** — meaningless once memory is windowed, and ungradeable per answer by the eval harness.

## Consequences

- Confidence is **derived, never authored**, and recomputable from `citation_verdicts`: the answer row stores the components (claim-state counts, distinct supporting documents), the base, the band, the ceiling gates applied with their constants, the cut-points in force and a `confidence_version`.
- The bands' cut-points are **knobs fitted by the eval harness**, not constants: high begins at the smallest base whose full-support precision clears 0.90 while keeping a usable share of answers, medium at the next. Changing them re-derives history rather than orphaning it.
- A band is **only as accurate as the verifier's labels** — a 0.90 precision target at "high" is 0.90 against HHEM's judgements, not against a human annotator's.
- Confidence is a property of **one answer record**, never a conversation. A follow-up whose supporting chunks are not re-retrieved into this turn's evidence set will legitimately score low, which makes prior-turn re-retrieval a requirement on conversation memory rather than an optimisation.
- Zero support is a **state**, not a low band: an answer none of whose claims any source supports is `insufficient_support`, presented distinctly from "low confidence".
- The claim denominator depends on the sentence splitter, so a splitter change is a `confidence_version` bump even though no threshold moved.
