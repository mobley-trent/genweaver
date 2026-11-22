# Domain docs

**Layout: single-context.** One glossary and one ADR directory for the whole repo — no per-package contexts.

## Where things live

| Path | Contents |
| --- | --- |
| `GLOSSARY.md` | The ubiquitous language: the project's terms, defined once, one meaning each. |
| `docs/adr/NNNN-slug.md` | Architecture Decision Records, one decision per file, four-digit sequence, kebab-case title. |

Both may not exist yet. Create them when the first term or the first decision appears; do not scaffold empty files.

## Rules for consumers

- **Read `GLOSSARY.md` before naming anything** — code, issues, tickets, commit messages, PR bodies. Use the glossary's terms verbatim, including casing. Do not introduce a synonym for a term that already exists.
- **Add terms as you define them.** When work settles the meaning of something the glossary doesn't cover, add the entry in the same change rather than leaving it implicit in a ticket.
- **Check `docs/adr/` before proposing a structural change.** An existing ADR that covers the area is binding unless the new work explicitly supersedes it.
- **Write an ADR for decisions that are expensive to reverse**: data model, storage and retrieval choices, public interfaces, deployment topology, auth boundaries. Skip it for choices that a later commit can simply undo.
- **ADRs are append-only.** To change a decision, write a new ADR that supersedes the old one and mark the old one `Superseded by NNNN`. Do not rewrite history.
- **Issue bodies and tickets may quote the glossary** but must not redefine it. A disagreement about a term is a glossary change, raised as its own issue.

## Format

Minimal ADR skeleton:

```markdown
# NNNN. <Decision in the imperative>

- Status: Proposed | Accepted | Superseded by NNNN
- Date: YYYY-MM-DD

## Context
What forces are at play.

## Decision
What we are doing.

## Consequences
What becomes easier, what becomes harder, and what we are now committed to.
```
