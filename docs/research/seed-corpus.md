# Seed corpus: ten PDFs for the eval harness

Resolves [Choose the ten seed corpus PDFs](https://github.com/mobley-trent/genweaver/issues/20). The corpus **profile** was fixed by [Design the eval harness](https://github.com/mobley-trent/genweaver/issues/10): ten open-licensed English PDFs, ~250 pages, one set of documents that is both the eval and the demo corpus. This note records which ten, why, and the evidence behind every field in `evals/corpus.json`.

## The set

Ten documents, **277 pages**, ~12.1 MB, every page carrying a text layer. All are fetched by `sha256` into `.cache/corpus/` and never committed.

| # | id | Title | Publisher | Pages | Licence | Tags |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `nist-ai-rmf-1.0` | Artificial Intelligence Risk Management Framework (AI RMF 1.0) | NIST | 48 | public domain (US) | identifiers, tables, figure, cross-page |
| 2 | `ncsc-ce-3.3` | Cyber Essentials: Requirements for IT Infrastructure v3.3 | NCSC (UK) | 26 | OGL v3.0 | identifiers, tables, figure, cross-page |
| 3 | `rfc-9111` | HTTP Caching | IETF | 35 | IETF Trust / BCP 78 | identifiers, tables, cross-page |
| 4 | `rfc-9457` | Problem Details for HTTP APIs | IETF | 16 | IETF Trust / BCP 78 | identifiers, prose, cross-page |
| 5 | `rfc-9562` | Universally Unique IDentifiers (UUIDs) | IETF | 46 | IETF Trust / BCP 78 | identifiers, tables, figure, cross-page |
| 6 | `tacl-lost-in-the-middle` | Lost in the Middle: How Language Models Use Long Contexts | ACL (TACL 12:157–173) | 17 | CC BY 4.0 | figure, tables, prose, cross-page |
| 7 | `nhtsa-early-2022` | Early Estimate of Motor Vehicle Traffic Fatalities in 2022 | NHTSA | 5 | public domain (US) | tables, figure, disagreement |
| 8 | `nhtsa-overview-2022` | Overview of Motor Vehicle Traffic Crashes in 2022 | NHTSA | 18 | public domain (US) | tables, figure, cross-page, disagreement |
| 9 | `cisa-aa24-317a` | 2023 Top Routinely Exploited Vulnerabilities | CISA/FBI/NSA + partners | 30 | TLP:CLEAR | identifiers, tables, cross-page |
| 10 | `bjs-cv-2023` | Criminal Victimization, 2023 | BJS (US DOJ) | 36 | public domain (US) | tables, figure, cross-page |

The tag vocabulary is closed and means one thing each:

- **identifiers** — codes, clause numbers, field names, CVE/CWE ids: the lexical branch's material.
- **tables** — at least one real table inside the ~2000-token atomic ceiling.
- **figure** — at least one figure with a caption.
- **cross-page** — a section long enough that a chunk cannot avoid crossing a page boundary.
- **prose** — continuous prose with no tables or figures (the density extreme where a chunker has only headings to work with).
- **disagreement** — one half of the fact-disagreeing pair.

## Why these ten

Three constraints did the choosing: an unambiguous licence, a full text layer, and Docling-parseable structure. Within those, the set was built to cover the profile's properties rather than to pile up similar documents:

- **Identifier density** comes from four different identifier grammars — NIST/NCSC control codes, IETF field and directive names, CVE/CWE ids — so the lexical branch is exercised against more than one convention.
- **Tables** are the dominant structure (17 in the 2022 overview, 16 in the BJS report, 15 in the AI RMF), with sizes that stay inside a single atomic table chunk.
- **Figures with captions** appear in eight of the ten; the UUID RFC alone contributes 31 bit-layout figures.
- **The disagreement pair** is two publications of the same agency about the same year (below), which is the cleanest kind of conflict: nothing about the topic, publisher or genre differs, so a wrong answer cannot be blamed on retrieval finding a different domain.
- **One on-topic paper** (Lost in the Middle) is included deliberately: its subject is position bias in long contexts, which is the system's own retrieval problem, and its terms recur in the corpus so cross-document questions have somewhere to land.

## Licence evidence

Every licence is one the ticket allows: local storage and redistribution of the **unmodified** file. A no-modification licence is acceptable because ingestion never alters the source PDF.

| Licence | Exact statement relied on | Source |
| --- | --- | --- |
| NIST AI 100-1 | "Works authored by NIST employees are not subject to Copyright protection within the United States; foreign rights are reserved. To the extent NIST may assert rights outside of the United States, the public is granted the non-exclusive, perpetual, paid-up, royalty-free, worldwide right to reprint works in all formats… and derivative works." | [NIST licensing statements](https://www.nist.gov/open/license) |
| NCSC CE v3.3 | "Content on the Websites is, unless stated otherwise, subject to Crown copyright. … you may use or reuse the content published on the Websites without prior permission but must adhere to and accept the terms of the Open Government Licence (OGL) v3.0. You must acknowledge the source of the content and include a link to the Open Government Licence wherever possible." | [NCSC terms](https://www.ncsc.gov.uk/section/about-this-website/terms-and-conditions) |
| RFC 9111 / 9457 / 9562 | "Copyright (c) 20xx IETF Trust and the persons identified as the document authors. All rights reserved. This document is subject to BCP 78 and the IETF Trust's Legal Provisions Relating to IETF Documents … in effect on the date of publication." | [IETF Trust legal provisions](https://trustee.ietf.org/license-info) |
| TACL paper | "© 2024 Association for Computational Linguistics. Distributed under a CC-BY 4.0 license." (printed on page 1) | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| NHTSA 813 428 / 813 560, BJS NCJ 309335 | Works of the United States Government are not subject to copyright protection in the United States, 17 U.S.C. §105. | [USA.gov copyright](https://www.usa.gov/government-copyright) |
| CISA AA24-317A | "This document is marked TLP:CLEAR. … Subject to standard copyright rules, TLP:CLEAR information may be distributed without restriction." | [CISA TLP](https://www.cisa.gov/tlp) |

Two judgement calls, recorded so a later reader can reverse them:

- **NCSC** states Crown copyright in the PDF and licenses reuse through its site terms, which name OGL v3.0. That is a publisher-term licence rather than a licence printed on the document, but the terms are explicit and the reuse right is unconditional apart from attribution.
- **CISA** co-authors are international agencies whose contributions may carry Crown copyright in their own jurisdictions. The advisory itself declares TLP:CLEAR and distribution without restriction, and the US contributions are §105 public domain.

## The disagreement pair

Both are NHTSA publications about **2022 traffic deaths**, five pages and eighteen pages, and they disagree on the number, the baseline and the direction of the year-over-year change:

| Document | 2022 deaths | 2021 baseline | Change |
| --- | --- | --- | --- |
| `nhtsa-early-2022` (DOT HS 813 428, April 2023), PDF page 1 | **42,795** (projection) | 42,939 | **−0.3 %** |
| `nhtsa-overview-2022` (DOT HS 813 560, June 2024 revised), PDF page 1; state table PDF page 17 | **42,514** (final) | 43,230 (revised) | **−1.7 %** |

The early estimate is explicit that the counts "will be further revised as the FARS final file … " becomes available; the final overview supersedes it. The disagreement is therefore *real but explainable*: a question such as "How many people died in motor vehicle crashes in 2022, and how much did that change from 2021?" has two defensible answers in this library, and the sources are otherwise identical in topic and genre. That is exactly the shape the confidence gates need — retrieval cannot resolve it by preferring a better-matched document, and an answer must either pick a side with a caveat or end up with claims its own sources only partly support.

## Structural coverage

| Property | Where it is exercised |
| --- | --- |
| identifier-heavy | NIST subcategory codes (GV-1.1, MEASURE 2.5); NCSC assessment requirements; RFC field/directive/version names; CVE/CWE ids in the CISA advisory |
| real tables | 17 (NHTSA 813 560), 16 (BJS), 15 (AI RMF), 6 (RFC 9562), 3 (NHTSA 813 428), 2 each (NCSC, RFC 9111, CISA, TACL) |
| multi-page section | AI RMF core-functions and MEASURE chapters; RFC 9111 §4; RFC 9562 version clauses; CISA technical details; BJS offence sections; TACL experiments |
| figure with caption | 31 (RFC 9562), 17 (TACL), 12 (AI RMF), 11 (NHTSA 813 560), 4 (NHTSA 813 428), 2 (BJS), 1 (NCSC) |
| prose without tables | RFC 9457 (16 pages, no tables or figures) |

## Tenant subsets

The two libraries the confidence gates need live in `evals/tenants/`:

- `single-document.json` — the final 2022 overview alone. A 2022 fatality question has one authoritative source here.
- `two-documents.json` — the early estimate plus the overview. The same question now has conflicting evidence.

Holding topic and genre constant is the point: the only difference between the two tenants is whether the disagreeing source is present.

## Rejected candidates

| Candidate | Why not |
| --- | --- |
| NIST SP 800-63B-4 (129 pp) | Would have made the password rule (15-character minimum) disagree with NCSC's 12-character rule — a real conflict between two current authorities — but 129 pages pushes the corpus to ~330 and swallows the page target. Kept as the first-choice upgrade if a second disagreement pair is ever wanted. |
| RFC 7519 (JWT) | RFC Editor renders no PDF for it (HTML/text only), and the manifest is PDF-first. |
| Census P60-282, Income in the United States: 2023 (59 pp) | Rich tables, but redundant with BJS and NHTSA for the table property and 12 pages over the remaining budget. |
| GAO-24-106463 | `gao.gov` returned 403 to non-browser requests; not worth a fragile fetch in a nightly corpus download. |
| WHO 2021 air-quality guidelines vs EPA PM2.5 standard | A crisp numeric disagreement (5 vs 9 µg/m³), but the WHO document is ~290 pages and the EPA statement is a fact sheet too thin to chunk meaningfully. |

## Docling parse check

Two of the three parse facts were verified for every document; the third was not.

- **No OCR-only pages.** `pdftotext -layout` returns text for every page of every document — zero pages with an empty text layer — so Docling can run without OCR. This is recorded per document as `docling.ocr_only_pages: 0`.
- **Heading material present.** Every document carries a machine-extractable heading hierarchy to find: NIST's numbered chapters and subcategory codes, NCSC's numbered requirement sections, the RFCs' numbered sections (with a Contents tree), NHTSA's numbered tables and figures, BJS's offence sections, CISA's technical-detail subsections.
- **Docling itself was not run.** The dependency install stalled on the CUDA wheels of the default PyPI `torch` (12 minutes, no progress) and was abandoned rather than left half-done. The conversion therefore remains to be observed; the manifest says `docling.status: "not-run"` for all ten rather than claiming a result.

The first place it can be observed is the harness's own `evals build-index`, which parses the PDFs with Docling. To check it sooner:

```bash
uv venv --python 3.12 .cache/docling-venv
uv pip install --python .cache/docling-venv/bin/python docling
for f in .cache/corpus/*.pdf; do .cache/docling-venv/bin/docling --to md --output .cache/docling-out "$f"; done
```

If a document turns out to produce no heading tree, the ones to revisit are `ncsc-ce-3.3` (heavy numbered lists) and `bjs-cv-2023` (dense statistics tables); the RFCs and NIST documents are the lowest risk because their headings are numbered.

## Fetching

`corpus.json` is the manifest the harness downloads from. A fetch is: GET `url` once, verify `sha256` and `bytes`, store under `.cache/corpus/<id>.pdf`. A hash or size mismatch is a hard failure, never a silent re-download — the eval gate cannot be reproducible against a document that changed underneath it.
