# genweaver

A production-grade RAG assistant over your own PDFs. Upload documents, ask questions, and get answers whose citations are **verified** against the retrieved source rather than merely attached.

Built to be local-first and deployable the way open-source projects are — clone, set env, `docker compose up` — with invite-gated accounts.

## Status

**Specification in progress — there is no runnable code yet.**

The architecture is being decided as a map of decision tickets in this repo's issues: [Map: genweaver — a production-grade RAG assistant](https://github.com/mobley-trent/genweaver/issues/1). Each ticket resolves exactly one decision, and blocking edges show what can be taken next. The spec is complete when no decisions remain.

## Shape

```
PDFs → parse → chunk → embed → Qdrant → retrieve → LLM → verified citations
                                                              ↓
                                                    confidence + cost
```

Planned capabilities: document upload and indexing, page-accurate source citations, citation verification, answer confidence, conversation memory, per-user cost tracking, and an eval harness that makes retrieval quality measurable — the reason this claims "production grade" rather than asserting it.

**Stack:** FastAPI · Qdrant · PostgreSQL · Docker Compose. Chat and embedding providers are planned to sit behind one seam: chat is intended to be provider-agnostic, with DeepSeek wired first (it is the only key available for testing), and embeddings sourced from a separate local model — DeepSeek offers no embeddings endpoint.

## Repo docs

- [`docs/agents/issue-tracker.md`](docs/agents/issue-tracker.md) — where work is tracked and how the decision map is operated
- [`docs/agents/domain.md`](docs/agents/domain.md) — glossary and ADR conventions
- [`AGENTS.md`](AGENTS.md) — instructions for agents working in this repo
