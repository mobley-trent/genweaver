# One tenant-partitioned collection, with BM25 over payload text as the lexical branch

**Status:** accepted

Every chunk lives in **one** Qdrant collection per embedding identity — named `chunks__<provider>__<model>__<dims>` — with `owner_id` indexed as a keyword field carrying `is_tenant: true`. Tenancy is therefore a payload partition, not a collection per user. Retrieval is hybrid: a dense HNSW branch, plus a lexical branch that is **BM25 computed by Qdrant over a full-text index on the payload's display text**. The two are fused with reciprocal rank fusion at `k: 60`, and the readiness gate from [ADR 0001](./0001-postgres-ingestion-queue-and-staged-chunks.md) is applied after fusion, before hydration.

Two choices carry most of the reasoning, and both are ones a reader would otherwise assume were accidents.

**No sparse vectors.** Hybrid retrieval designs usually add a sparse vector — BM25 via FastEmbed, miniCOIL, or SPLADE — because term matching is what finds identifiers, names and rare words that embeddings blur, and PDFs are full of them. Qdrant ≥ 1.20 can rank a payload field directly through a scored full-text index, deriving term frequency, document frequency and average document length from text it already stores. The lexical branch therefore costs an index instead of an extra vector per chunk, a second inference seam, and a service in `docker compose`. What it gives up is term expansion: plain BM25 cannot match a synonym the document never uses, which is precisely why dense retrieval remains the other half. Adding a sparse vector later is a live collection's config change plus a backfill from the same payload text, so this is not a one-way door.

**HNSW `m: 0` with `payload_m: 16`.** The graph is built per tenant filter value rather than collection-wide, so a filtered search does not traverse a graph dominated by other tenants' points. The cost is stated plainly: an **unfiltered** query is a poor search, which is acceptable only because no product query is unfiltered — every retrieval reaches Qdrant through the one filter builder that scopes `owner_id` and `is_active`.

Point ids are deterministic: `uuid5(document_id:chunker_version:chunk_index)`. Re-embedding a chunk overwrites its point rather than appending a duplicate, which is what makes ingestion's "the vector store is the progress record" resumption idempotent; a `chunker_version` bump produces distinct ids so a reindex can tell old points from new.

## Considered Options

- **Dense-only retrieval** — one index, one model call per query. It underperforms exactly where PDFs are hardest (part numbers, statute numbers, names), and ships instead as an eval-harness control arm.
- **Sparse-vector hybrid (FastEmbed BM25, miniCOIL, SPLADE)** — stronger lexical matching for learned models, at a second vector per chunk, a second inference path, and for fitted models another service to operate.
- **One collection per user** — strongest structural separation, but unbounded collections, schema and index creation on the signup path, and an embedding migration that fans out across every user.
- **User-defined sharding, or tiered multitenancy** — better isolation than a payload partition, but each shard carries its own index structures, the wrong shape for many small tenants.
- **DBSF instead of RRF** — score-distribution fusion, tuneless. It assumes each branch's scores behave well, which is unverified for BM25 over a small personal corpus.
- **Qdrant's default RRF `k` of 2** — trusts each branch's first result very steeply; 60 is the literature value and keeps results comparable to published work.

## Consequences

- The collection name **is** the embedding identity. A model or dimension change is a new collection and a reindex; vector size and distance are immutable once created.
- Indexed fields are `owner_id` (`is_tenant`), `document_id`, `is_active` and the scored text index on `text`. Strict mode rejects filters on unindexed fields, so the retrieval filter may never grow a field without an index in the same change.
- The Qdrant filter is a performance mechanism, **not** the security boundary; hydration re-checks document ownership and readiness in Postgres. A filter bug yields a short answer, not another tenant's text.
- The lexical branch indexes **display text only**, never the contextual prefix — the prefix repeats each document's title on every chunk, which flattens BM25's discrimination. The prefix therefore helps the dense branch alone.
- Lexical analysis (word tokenizer, lowercasing, no stemmer, no stopwords — chosen because the corpus is identifier-heavy and of unknown language) changes retrieval behaviour, so it joins `chunk_config_hash`; changing it is a `chunker_version` bump and a reindex.
- BM25 statistics are scoped to the tenant, so "rare" means rare in the library the answer may actually cite.
- A fused score is **ordinal, not a similarity**: adjacent RRF ranks carry no calibrated distance. Work on answer confidence must not read it as closeness to a source.
- Prefetch depth (50), fused limit (20) and BM25 `k`/`b` are eval-swept knobs, not part of this decision.
- The deployment requires **Qdrant ≥ 1.20**; hybrid retrieval adds no service to compose.
