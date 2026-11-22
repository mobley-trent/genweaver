# Triage labels

Five canonical roles. Each label string equals its role name — the defaults, unmodified.

| Role | Label | Meaning |
| --- | --- | --- |
| Triage | `needs-triage` | New and unassessed. Nothing else has happened yet. |
| Needs info | `needs-info` | Not actionable yet; a question has been asked of the reporter. |
| Agent-ready | `ready-for-agent` | Specified well enough that an agent can implement it without further input. |
| Human-ready | `ready-for-human` | Specified well enough, but a human must do the work (access, judgement, relationships). |
| Won't fix | `wontfix` | Deliberately not being worked on. Terminal. |

## Rules for consumers

- An issue carries **at most one** of these labels at a time; remove the old label when adding the next.
- Use the exact strings above. Do not invent synonyms (`triage`, `bug:triage`, `needs triage`) — if a label is missing in the tracker, create it with this string rather than substituting your own.
- `needs-info` and `wontfix` are answers, not stalls: leave a comment saying what is missing, or why it will not be done.
- A label change should be accompanied by a comment explaining it, so the state machine is legible in the issue timeline.
- `ready-for-agent` means the brief is self-contained: context, acceptance criteria, and the files or areas to touch are all in the issue body.
