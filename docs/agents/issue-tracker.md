# Issue tracker

Work for this repo is tracked in **GitHub Issues**, driven through the [`gh`](https://cli.github.com) CLI.

## Repo

Configured remote: `origin` → `https://github.com/mobley-trent/genweaver.git` (HTTPS, matching the `gh` auth protocol). The `gh` CLI resolves the target repo from `origin`, so every workflow below must be run from inside this clone.

The repo exists on GitHub as a **public**, empty repository (`https://github.com/mobley-trent/genweaver`). No commits have been pushed yet, so `gh issue` and `gh label` work but there is no code history on the remote.

## How skills use this

- `to-spec` — publishes a spec as an issue (`gh issue create --body-file -`)
- `to-tickets` — publishes one issue per ticket, declaring blocking edges as text in each body (`Blocked by: #12`)
- `triage` — reads and advances issues with `gh issue list`, `gh issue view`, `gh issue edit --add-label/--remove-label`, `gh issue comment`
- `wayfinder` — opens and resolves decision tickets as issues
- `pr` — reads the originating issue for context before writing a PR body

## Labels

The five canonical triage labels are defined in [`triage-labels.md`](./triage-labels.md) and are already created in this repo. To recreate them in a fresh clone or another repo:

```bash
gh label create needs-triage    --description "New issue, not yet triaged"        --color FBCA04
gh label create needs-info      --description "Waiting on more information"       --color D4C5F9
gh label create ready-for-agent --description "Specified well enough for an agent" --color 0E8A16
gh label create ready-for-human --description "Needs a human to act"               --color 1D76DB
gh label create wontfix         --description "Will not be worked on"              --color FFFFFF
```

## Wayfinding operations

The `wayfinder` skill keeps its map and decision tickets here. GitHub supports the native relationships, so no body conventions are needed.

| Concept | GitHub expression |
| --- | --- |
| Map | the single issue labelled `wayfinder:map` |
| Ticket | a child issue of the map, labelled `wayfinder:<type>` — `research`, `prototype`, `grilling`, `task` |
| Blocking | a native issue dependency (`blockedBy` / `blocking`), which renders in the GitHub UI so the frontier is visible without opening the map |
| Claim | the issue's assignee |
| Frontier | open, unassigned child issues whose `blockedBy` issues are all closed |

Create a ticket as a child of the map, then wire blockers in a second pass (issues need node ids before they can reference each other):

```bash
gh issue create --title "..." --label wayfinder:grilling --body-file -

# child of the map
gh api graphql -f query='mutation($p:ID!,$c:ID!){addSubIssue(input:{issueId:$p,subIssueId:$c}){issue{number}}}' \
  -f p="$MAP_NODE_ID" -f c="$TICKET_NODE_ID"

# blocked by another ticket
gh api graphql -f query='mutation($i:ID!,$b:ID!){addBlockedBy(input:{issueId:$i,blockingIssueId:$b}){issue{number}}}' \
  -f i="$BLOCKED_NODE_ID" -f b="$BLOCKER_NODE_ID"
```

Node ids come from `gh issue view <n> --json id --jq .id`.

Read the map and its frontier:

```bash
gh api graphql -f query='{repository(owner:"mobley-trent",name:"genweaver"){issue(number:MAP){subIssues(first:50){nodes{number title state assignees(first:1){nodes{login}} blockedBy(first:20){nodes{number state}}}}}}}'
```

Claim a ticket with `gh issue edit <n> --add-assignee @me`; resolve it with a resolution comment, `gh issue close`, and a line in the map's Decisions-so-far section.

## PRs as a request surface

`false`

Issues only. Pull requests are not part of the triage queue: external PRs are reviewed and merged, not triaged as requests. Set this to `true` if you want `triage` to pull PRs into the queue as well.

## Conventions

- One issue per unit of work; keep the issue body agent-ready (context, acceptance criteria, files to touch).
- Declare dependencies as text in the body — `Blocked by: #12`, `Blocks: #14` — not as labels.
- Reference issues from commits and PRs as `#<n>` so GitHub links them automatically.
- Close with a comment naming the commit or PR that resolved it.
