# Serve a server-rendered UI from the api image, with one hand-written stream client

- Status: Accepted
- Date: 2026-11-24

## Context

The product has no face. [ADR 0012](0012-one-compose-stack-with-a-caddy-overlay.md) already fixed the
constraint it must live inside — *"#16 must ship a same-origin UI inside the api image — no separate
frontend service, no CORS"* — and [ADR 0009](0009-serve-rest-with-sse-over-fetch.md) fixed the wire:
answers are Server-Sent Events over a `fetch` stream from a POST, never `EventSource`, with a cookie
session, a double-submit CSRF token and RFC 9457 errors.

Three shapes were on the table: server-rendered pages from FastAPI (Jinja2), a small SPA built with
Vite, or no UI at all. The third was dead on arrival — a public instance with an invite flow but no
sign-in page cannot admit anyone, and the deployment decision had already committed to a same-origin
UI. Between the first two, the ticket's premise that SSR means "no build step" is only half the
argument: **a hand-written stream client is mandatory either way**, because `EventSource` cannot POST
and putting the question in a URL would put it in proxy logs and browser history.

What is actually being chosen is how much of the application that client owns.

## Decision

**Nine surfaces, server-rendered by the api with Jinja2, and exactly one client-side state machine:
the answer stream.**

| Route | Surface |
| --- | --- |
| `GET /login`, `POST /login` | sign in, plus the login-backoff message |
| `GET /invite/{token}`, `POST /invite/{token}` | redeem an Invite |
| `GET /password/reset/{token}`, `POST …` | redeem an admin-issued reset token |
| `GET /password`, `POST /password` | change own password |
| `GET /` | Conversation list, `?before=<cursor>` "Load more" |
| `GET /conversations/{id}` | the chat: stream, claim segments, citation chips, band, sources & cost |
| `GET /documents` | upload, ingestion status, retry, delete |
| `GET /usage` | own spend and budgets |
| `GET /admin` | invites, accounts, deployment usage (admin only) |

**No build step and no Node in the image.** Templates and static files ship inside the `api` target;
one hand-written stylesheet carries custom-property tokens, the system font stack and no web fonts.
Three ES modules — `api.js` (fetch, CSRF header, RFC 9457 problem decoding), `stream.js` (the
buffer-and-split SSE parser) and `chat.js` (the render state machine) — are served as static files
under a strict CSP with no inline script and no third-party origin.

**Chat rendering is a two-phase contract.** `answer_delta`s fill a plain `pre-wrap` block as they
arrive; `answer_completed` replaces that block with claim segments whose citation chips render
**pending**; `verification_completed` / `verification_degraded` resolve the chips in place and add
the band with its arithmetic ("High — 4 of 5 claims verified"). The evidence set, each member marked
`carried` or `retrieved`, and the turn's cost sit in a collapsible "this answer's sources & cost"
panel. Model output is rendered as **text with preserved line breaks, never as Markdown or HTML** —
the prompt is prose, and rendering model-authored markup is an injection surface the product does not
need. There is no regenerate control: a retry is a new Answer (#14).

**Every page except the chat works with JavaScript disabled.** Sign-in, invite redemption, password
reset, upload, the document list, the conversation list and usage are plain form posts with 303
redirects; only `/conversations/{id}` requires JS, and it says so with a link to the stored Answer's
JSON rather than a dead composer.

**The edge cap sits above the app cap, and the app owns the error.** Uploads are one file per request,
polled on `Retry-After` until `ready` or `failed`; the proxy's body ceiling is deliberately larger than
`UPLOAD_MAX_BYTES`, so a body the app would accept is never refused by Caddy with an untyped 413.

**Tokens live in the path, and the path is redacted.** `/invite/{token}` and `/password/reset/{token}`
are `Referrer-Policy: no-referrer`, are never echoed back beyond the hidden form field, and 303 to
`/login` once spent. The request log must redact the token segment on those two routes — handed to the
observability decision rather than left implicit.

**A 401 is a redirect, not a countdown.** A shared fetch wrapper sends any 401 to
`/login?next=<path>`, preserves the unsent question and, if the stream had already emitted
`answer_started`, the `answer_id`, so returning to the Conversation loads the persisted Answer. There
is no idle timer and no `/auth/me` heartbeat; `/auth/me` is read once per page load.

## Consequences

**Easier.** The deployment gains no artifact and no toolchain: `docker compose up` still builds one
Python image. The refusal paths (402/503), the invite errors, the login backoff and every list are
server-authored HTML, so they cannot drift from the API's error vocabulary. The whole UI except the
chat is exercisable with `curl` against the runbook. The CSP has one origin and no inline script.

**Harder.** The chat page is a hand-written renderer with a two-phase re-render, and its citation and
verdict state machine is the only client logic that will need tests of its own. Re-rendering at
`answer_completed` visibly re-flows the answer text — accepted, because holding tokens invisible until
completion is not streaming. `uvicorn --workers` multiplies the in-process verifier, so the api stays a
single instance (#15), and the server-rendered pages inherit that.

**Committed to.** The screen inventory above is the v1 surface: no document preview or download, no
cross-conversation search, no settings beyond password, no ingestion stream, no eval surface, no title
column on Conversations, no dark theme (a later `prefers-color-scheme` block over the same tokens).
Admin is invites, accounts and usage in the UI; the first admin is still `genweaver admin create`.
`GET /conversations/{id}` is the only route that fails without JavaScript, and the answer card holds
exactly one slot each for `insufficient_support`, `unverified` and an Interrupted answer — the wording
of those slots remains with the map's "what the assistant says when retrieval misses" fog.
