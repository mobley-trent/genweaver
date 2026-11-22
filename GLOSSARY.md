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
