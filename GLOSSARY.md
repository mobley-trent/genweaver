# genweaver

A local-first, invite-gated RAG assistant over user-supplied PDFs. This is the ubiquitous language for that system: the terms that mean something specific here, defined once.

## Language

### Identity and access

**Account**:
The identity a person signs in with, and the thing an Invite brings into existence. Every Account is exactly one Tenant, and the Account's id is that Tenant's id; no two Accounts share one.
_Avoid_: user, login, profile

**Invite**:
The single-use, expiring grant that is the only way a new Account comes to exist. It names the address it is intended for, but that address proves nothing: with no mail delivery, an Admin hands the Invite over themselves.
_Avoid_: invite code, signup link, invite token

**Role**:
An Account's standing in the deployment: `admin`, which may issue and revoke Invites, terminate Sessions and re-issue credentials, or `member`, which may not.
_Avoid_: permission, scope, group

**Session**:
One signed-in browser's authority to act as an Account, held server-side and revocable at any moment. A Session ends by logout, by idleness, by age, or by an Admin.
_Avoid_: token, cookie, login, JWT

**Deactivated account**:
An Account an Admin has suspended: it cannot sign in, none of its Sessions resolve, and everything it owns is exactly as it was, so reactivating it restores the Account as it stood. Distinct from deletion, which is the Account ceasing to exist.
_Avoid_: disabled user, banned account, suspended login

**Purge**:
The removal of everything a deleted Account owns — its documents, chunks, conversations, answers and the vectors derived from them — from every store holding a copy. The only operation in the system that destroys data beyond recovery, and it leaves untouched only what was never the Account's own: the spend it caused and the Invite that admitted it.
_Avoid_: hard delete, cascade delete, account wipe

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
The Account whose documents a single query may see. One Account is one Tenant; no answer may draw on another Tenant's documents.
_Avoid_: workspace, organization, profile

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

**Provider**:
A named implementation of a model seam — chat, embeddings or the verifier — that a deployment selects by configuration. Two providers of one seam are interchangeable only when their model identities match; changing the provider is a change of provenance, not only of wiring.
_Avoid_: backend, vendor, client

**Embedding identity**:
The provider, model, dimensions and pinned revision that together decide which collection a chunk belongs to and whether two vectors may be compared. It is recorded per chunk, so a changed identity shows up as a changed collection rather than as silently mismatched vectors — two revisions of one model are two vector spaces.
_Avoid_: embedding model, vector space key

**Serving index**:
The collection the retrieval alias currently points at: the vectors an answer is actually drawn from. A rebuild fills a collection that is not the serving index until it publishes it, and a rollback moves the alias back to the collection the run superseded.
_Avoid_: live collection, current index, active collection

**Reindex run**:
One attempt to rebuild a set of documents into a target indexing generation — the generation it produces, the documents it intends to rebuild (fixed when it opens), and whether it publishes by moving the serving index or by replacing each document's generation in place.
_Avoid_: reindex job, migration, rebuild task

**Model registry**:
The code-level table of what a known model is: its context window, output ceiling, thinking default, structured-output mode, price key and the revision last observed. Consulted instead of guessed at call sites, and holding no prices and no selections.
_Avoid_: model catalogue, provider config, model list

**Prompt version**:
The identifier of the instruction contract an Answer was generated under, recorded on the Answer so that answers written under different instructions stay distinguishable and comparable.
_Avoid_: prompt id, template version, system prompt

**Rewrite version**:
The identifier of the instruction contract a Standalone query was produced under, recorded apart from the Answer's Prompt version, so that a change in how follow-ups are resolved is distinguishable from a change in how answers are written.
_Avoid_: prompt version, query version

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

**Indexing generation**:
The set of chunks one Ingestion of a document produced under one Chunker version and one Chunk config hash, and the only set that document's own counts describe. A chunker change writes a new generation beside the old one rather than overwriting it, which is what lets a Stale chunk be told apart from a current one. An older generation keeps being served only until its own document's replacement is published, so a library mid-reindex is mixed per document, never per chunk.
_Avoid_: batch, pass, indexing version

**Maintenance sweep**:
The periodic pass that purges staged chunks of failed or deleted documents and fails documents whose job was lost.
_Avoid_: cleanup cron, janitor, garbage collector

### Conversations

**Conversation**:
An ordered sequence of Answers owned by one Account, and the thing a person resumes when they come back to a question. It holds no derived state of its own: confidence belongs to an Answer, and anything carried from one Answer to the next is a prompt-time concern, not a property of the Conversation.
_Avoid_: thread, chat, session

**Conversation memory**:
What carries from one Answer to the next inside a Conversation: the recent exchanges themselves, and the sources the earlier Answers cited. It exists only while a question is being answered — nothing about it is stored as a property of the Conversation, and it never crosses into another Conversation.
_Avoid_: context, chat history, memory store, session state

**History window**:
The most recent exchanges of a Conversation, verbatim, that a follow-up is answered in the context of. Bounded and deliberately small; an Interrupted answer is not part of it, because it has no sources and no verified text to build on.
_Avoid_: transcript, full history, context window

**Standalone query**:
The question a follow-up is turned into before anything is retrieved: self-contained, with its pronouns and ellipses resolved from the History window, so that retrieval is never run on text whose subject is missing. It is not the question the person asked, and it is never shown as one.
_Avoid_: rewritten question, expanded query, search query

**Query rewrite**:
The act of turning a question into a Standalone query. A follow-up always gets one; a first question does not, because there is nothing to resolve it against.
_Avoid_: query expansion, reformulation, query understanding

**Carried chunk**:
A chunk an earlier Answer in the same Conversation cited, re-admitted to this Answer's Evidence set because the follow-up may still be about it. A carried chunk is not re-retrieved and ranking cannot displace it; if its source is gone, it is dropped and the follow-up is simply a miss.
_Avoid_: pinned chunk, inherited source, previous document

### Answers and verification

**Answer**:
The persisted result of one question: the text as delivered, its Claims and Citations with their verdicts, its Evidence set, its Confidence band or state, its cost and its provenance. Streaming is how an Answer is delivered, never what an Answer is — a client that disconnects still leaves one behind.
_Avoid_: response, completion, message, output

**Interrupted answer**:
An Answer whose provider stream broke after it had begun. It keeps the text that arrived, carries no Claims, no verdicts and no Confidence band, and the system never resumes or regenerates it on its own initiative.
_Avoid_: partial answer, truncated answer, failed answer

**Unverified answer**:
An Answer whose Citation verification did not run, so it carries no Confidence band at all. Shown as "support not checked", never as a low band, because a verifier's silence says nothing about support.
_Avoid_: low confidence, unchecked answer

**Evidence set**:
The chunks an answer was answered against — retrieved for it, or carried from an earlier Answer in the same Conversation — and the only chunks its citations may point at. A citation to anything outside it is invalid. Every member is either retrieved or carried, and says which.
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

**Verification run**:
One attempt to verify every Claim of an Answer under one verifier and one set of thresholds. Verdicts belong to a run rather than to the Citation, so re-deriving after a threshold change adds a run instead of rewriting what the Answer actually shipped with; the newest complete run is the one the Answer shows, and an Answer with no complete run is unverified rather than failed.
_Avoid_: verification pass, re-check, verdict batch

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

### Evaluation

**Gold source**:
The span of a named document that a question's answer may legitimately rest on, labelled by a person before the system is run, and addressed as a document, a PDF page ordinal and a quote rather than by any identifier the index happens to give it.
_Avoid_: ground truth chunk, reference passage, expected source

**Gold chunk set**:
The chunks of the index currently in force that contain a question's gold sources, resolved at run time rather than stored, so that a reindex changes which chunks answer a question without changing the question's labels.
_Avoid_: expected chunks, target ids

**Gold fact**:
One atomic assertion that an answerable question's correct answer is expected to make, labelled individually so an answer can be scored on which facts it stated and which it invented.
_Avoid_: expected answer, reference answer

**Eval arm**:
One named pipeline configuration under comparison by the eval harness — the baseline, a control, or an ablation of a single knob.
_Avoid_: variant, experiment, configuration

**Eval run**:
One evaluation of one eval arm against one dataset version in one mode, reported as a single record identified by the configuration it ran under.
_Avoid_: benchmark, test run

**Baseline**:
The committed metrics an eval run is compared against, carrying the spread measured for each metric and the tolerance it is gated with, and changed only as a reviewed diff.
_Avoid_: golden file, snapshot, reference run

### Cost and budget

**Usage row**:
One immutable record of one provider call attempt — the tokens the provider reported, or that we estimated when it reported none, and the money they cost — linked to the Answer, ingestion or eval run that caused it. Retries, failures and aborted streams are rows too, because the provider billed them.
_Avoid_: billing event, log entry, usage record

**Price key**:
The label a model's registry entry carries to name which rates price its calls. A model carries a price key; it never carries a price.
_Avoid_: price id, model id, rate name

**Rate card**:
The checked-in table of per-million-token rates by price key, each block naming an effective date and separate cache-hit, cache-miss and output rates for peak and off-peak. Loaded at boot, and holding no models and no selections.
_Avoid_: price table, tariff, price list

**Price version**:
The identifier of the rate card state that priced a usage row, written on the row so that a later rate change never re-prices an answer already given.
_Avoid_: price date, table version

**Peak window**:
The times a provider charges its higher rate — for DeepSeek, 01:00–04:00 and 06:00–10:00 UTC Monday to Friday, with every other hour off-peak. Recorded as data in the rate card, so each call is priced by when it was made.
_Avoid_: busy hours, surge pricing

**Budget**:
A spending ceiling in US dollars over a window, held either per Account (monthly, hard; daily, soft) or deployment-wide (monthly, hard). A hard budget refuses admission; a soft one only warns.
_Avoid_: quota, limit, allowance

**Admission check**:
The pre-flight test that prices an answer's upper bound against what remains of its Account's and the deployment's budgets, before any provider call is made. It admits or refuses; it never stands in for the usage rows that record what was actually spent.
_Avoid_: quota check, pre-flight, throttle

**Usage scope**:
Whether a usage row was caused by product traffic or by the eval harness. Eval rows spend the same key and live in the same ledger, but count toward no Account's or deployment's budget.
_Avoid_: category, source
