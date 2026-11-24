# genweaver

A local-first, invite-gated RAG assistant over user-supplied PDFs. This is the ubiquitous language for that system: the terms that mean something specific here, defined once.

## Language

### Documents and retrieval units

**Chunk**:
An indivisible retrievable unit of a document — the thing that is embedded, stored in the vector store, and cited. Chunks are derived from a document's structure, never authored.
_Avoid_: segment, passage, node, fragment

**Section path**:
The ordered chain of headings from the document title down to the heading a chunk sits under. It is context the chunk body alone does not carry.
_Avoid_: breadcrumb, heading path, outline path

**Contextual prefix**:
Text derived from a chunk's document and section path and prepended to its text before embedding, so a chunk that never repeats its subject can still be found by it. Never shown to the user and never cited.
_Avoid_: header injection, context header, enrichment

**Display text**:
A chunk's own text, verbatim from the document, as shown in a citation. Distinct from anything embedded.
_Avoid_: chunk text, content

### Provenance

**PDF page ordinal**:
The 1-based position of a page in the physical file, counting from the first page. What the parser reports, and what citations carry.
_Avoid_: page number, physical page

**Printed page label**:
The page number actually printed on the page face, which may diverge from the PDF page ordinal. Optional, because extraction cannot always recover it.
_Avoid_: page number, real page

**Canonical markdown**:
The single serialized rendering of a parsed document that every offset and quote refers to. Produced once per document and persisted.
_Avoid_: extracted text, plain text, source text

### Retrieval

**Tenant**:
The account whose documents a single query may see. One user is one tenant; no answer may draw on another tenant's documents.
_Avoid_: workspace, organization, account

**Dense branch**:
The retrieval branch that ranks chunks by embedding similarity.
_Avoid_: semantic search, vector leg

**Lexical branch**:
The retrieval branch that ranks chunks by how rare and how frequent their terms are, matching identifiers, names and rare words that embeddings blur.
_Avoid_: keyword search, sparse leg, BM25 search

**Fused ranking**:
The single ordered list produced by merging the branches' rankings by position. Ordinal, not a similarity measure.
_Avoid_: merged results, hybrid list

**Retrieval gate**:
The check that drops retrieved chunks whose document is not yet ready, applied after fusion and before hydration.
_Avoid_: readiness filter, document check

### Configuration and provenance

**Chunker version**:
A hand-bumped identifier for the chunking configuration a chunk was produced under. Behavioural change of the splitter, sizes or prefix bumps it.
_Avoid_: schema version, index version

**Chunk config hash**:
A fingerprint of the exact chunking parameters a chunk was produced under. A chunk whose fingerprint differs from the running configuration is stale.
_Avoid_: config version, checksum

**Stale chunk**:
A chunk produced under a chunker version or config hash that no longer matches the running configuration, and which a reindex must replace.
_Avoid_: outdated chunk, orphan

### Ingestion

**Ingestion**:
The pipeline that turns an accepted upload into retrievable chunks: parse, chunk, embed, activate.
_Avoid_: indexing, processing, pipeline run

**Ingestion stage**:
One of parse, chunk, embed or activate — the unit that a document's reported progress advances through.
_Avoid_: phase, step

**Ingestion job**:
The single unit of queue work that ingests one document, resumable from the stage artifacts that document already has.
_Avoid_: task, worker run

**Staged chunk**:
A chunk written by an ingestion that has not finished, and therefore invisible to retrieval.
_Avoid_: inactive chunk, partial chunk, pending chunk

**Active chunk**:
A chunk whose document finished ingesting; the only chunks retrieval may return.
_Avoid_: indexed chunk, live chunk, published chunk

**Maintenance sweep**:
The periodic pass that purges staged chunks of failed or deleted documents and fails documents whose job was lost.
_Avoid_: cleanup cron, janitor, garbage collector

### Answers and verification

**Evidence set**:
The chunks an answer was retrieved against, and the only chunks its citations may point at. A citation to anything outside it is invalid.
_Avoid_: context, window, retrieved documents

**Claim**:
A sentence-level assertion in an answer, delimited by the system rather than by the generator. Every claim must carry at least one citation.
_Avoid_: statement, sentence, span

**Citation**:
A pointer from a claim to the chunk that is said to support it, together with the quoted span the generator attributes to that chunk.
_Avoid_: reference, source, footnote

**Citation verification**:
The check that a citation's quote is really in the cited chunk and that the chunk supports the claim. Retrieval says a chunk may be relevant; verification says it supports what was said.
_Avoid_: citation checking, fact-checking, grounding

**Verified citation**:
A citation whose quote was located in the cited chunk and whose claim that chunk is scored as supporting.
_Avoid_: valid citation, grounded citation, good citation

**Partial citation**:
A citation whose quote was located but whose claim the cited chunk supports only weakly — a real source, insufficient support.
_Avoid_: weak citation, half-verified citation

**Failed citation**:
A citation whose quote could not be located in the cited chunk, whose chunk is not in the evidence set, or whose chunk does not support the claim.
_Avoid_: bad citation, broken citation, hallucinated citation

**Uncited claim**:
A claim carrying no citation at all. Distinct from a failed citation, which points somewhere that did not hold up.
_Avoid_: unsourced statement, bare claim

**Unchecked claim**:
A claim verification never ran on, because the verifier was unavailable or out of budget. Says nothing about whether the claim is supported.
_Avoid_: unverified claim, unvalidated claim

**Support share**:
The share of an answer's claims that its own verified sources back — a verified claim counts fully, a partial one by half, a failed or uncited one not at all. It is what the product means by confidence, and it is not a probability that the answer is correct.
_Avoid_: confidence score, certainty, probability, accuracy

**Confidence band**:
The three-way summary of a support share shown with an answer — high, medium or low — after the answer's ceiling gates have applied. A band is always accompanied by the claim counts behind it, never shown as a number.
_Avoid_: score, percentage, confidence level

**Insufficient support state**:
An answer whose claims none of its cited sources support, or which had no evidence set to draw on. A state of the answer, distinct from a low confidence band, because it says nothing was supported rather than little.
_Avoid_: low confidence, no answer, refusal
