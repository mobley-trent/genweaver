# Serve one cookie-authenticated REST surface, and stream answers as SSE over fetch

**Status:** accepted
**Date:** 2026-11-24

The HTTP surface is a single REST API at `/api/v1`, authenticated by the opaque session cookie
[ADR 0005](0005-accounts-are-invite-only-and-auth-runs-in-the-app.md) established, and answers are
delivered as **Server-Sent Events over a `fetch` stream** rather than over `EventSource` or a
WebSocket. An **Answer is a resource**: it is created by `POST /conversations/{id}/answers`, carries
a required idempotency key, can be fetched afterwards at `GET /answers/{id}`, and outlives the
connection that delivered it. Errors are RFC 9457 problem documents drawn from a closed code set.
Ingestion progress is **polled**, not streamed. There are no per-request retrieval or model knobs.

Three upstream decisions force most of this shape. Verification runs *after* the answer completes and
emits its verdicts as a terminal event ([ADR 0003](0003-verified-citations-with-a-local-verifier.md)),
and confidence is a derivation over those verdicts delivered in the same event
([ADR 0004](0004-confidence-is-a-support-share-not-a-probability.md)) — so the stream is
strictly one-way and its payload grows toward the end, which is the traffic SSE exists for and the
traffic a request/response body cannot carry. Auth is a cookie plus a double-submit CSRF token, with
no signing secret and no bearer token; a WebSocket would need its own ticket handshake to carry that
identity and its own origin checking, buying bidirectional traffic nothing in this product sends. And
budget refusal precedes the first token ([ADR 0008](0008-price-every-call-and-gate-spend-before-the-call.md)),
which only works if refusal is an ordinary HTTP error with no partial body to render — true of SSE
started after the admission check, and awkward over a socket that is already open.

**SSE over `fetch`, not `EventSource`.** `EventSource` cannot POST, and putting a question in a query
string puts it in proxy logs, browser history and `Referer`. A `fetch` response read as a stream costs
one small client helper and keeps the question in a body. The price is that the client writes its own
SSE parser; the payload per event is one JSON object, so that parser is a buffer and a `split`.

**No replay.** The stream carries `seq` but no `id:`/`Last-Event-ID`. Reconnecting mid-answer would
replay tokens into a renderer that may still hold the ones it already printed, and the answer is
persisted anyway, so `GET /answers/{id}` is both the simpler and the truthful reconnect.

**Answers outlive delivery.** A client disconnect stops the stream write and nothing else: the
tokens are already bought, verification is shielded per ADR 0003, and the persisted Answer is worth
having. A provider stream that breaks after the first token is the different case (ADR 0007): it is
persisted with status `interrupted`, its delivered text, and **no** claims, verdicts or band —
segmenting half an answer would invent the denominator confidence divides by. A break before the
first token leaves no Answer at all, only the usage row the ledger owes and an `error` event.

**Deletion is answered by snapshotting, not by cascading.** `DELETE /documents/{id}` removes the
document and its chunks, and past citations stay legible because the citation row captures what it
needs to render — document title, page ordinals, matched quote — at write time. An answer is history,
not a live view onto the library. The same rule is what lets
[Decide what deactivating an account does to its documents and sessions](https://github.com/mobley-trent/genweaver/issues/19)
decide retention without having to resurrect deleted sources.

**No request knobs.** `POST .../answers` carries a question and nothing else. Top-*k*, temperature,
model overrides and document filters are deployment facts that provenance records (ADR 0007), not
per-request dials that every stored answer would then have to carry and every eval arm would have to
pin.

**One open-surface list.** WebSocket, `EventSource`, long-poll, GraphQL, offset pagination, a custom
error envelope, `Last-Event-ID` replay, soft-deleted documents with a grace window, and SSE ingestion
status were all considered and rejected; the detailed contract — endpoint table, event fields, error
codes, limits — lives in the resolution of
[Set the API surface and streaming contract](https://github.com/mobley-trent/genweaver/issues/14),
which is the artifact an implementer reads.

## Considered Options

- **WebSocket** — bidirectional, and nothing here sends after the question; costs a ticket-based auth
  handshake, separate CSRF and origin handling, and a protocol state machine on both sides.
- **`EventSource` over GET** — a browser-native SSE client, at the price of the question in the URL.
- **Long-poll or one blocking JSON response** — no stream parser, and the response cannot show tokens
  as they arrive or verdicts before the answer text has finished.
- **Answers returned by the POST but not addressable** — smaller surface, and no way to see what a
  disconnected client lost.
- **Resumable streams via `Last-Event-ID`** — reconnection without a re-fetch, at the cost of a replay
  buffer per answer and duplicate-token rendering.
- **GraphQL** — one endpoint and client-shaped reads, and a second schema language beside Pydantic for
  a surface of ten resources.
- **Offset pagination and total counts** — simpler cursors, and drift plus a second query per page.
- **A custom `{error: {...}}` envelope** — fewer bytes, and a private convention where a standard
  problem document already carries a stable `type`, a human `title` and room for the budget extras.
- **Soft-delete with a purge window on a document** — reversible, and it makes every retrieval path
  carry a second visibility rule; account-level retention is the ticket that needs a window, not this.
- **SSE for ingestion status** — one streaming mechanism reused, for a page whose entire state changes
  four times.

## Consequences

- The client needs a small SSE-over-`fetch` reader, and the browser's `EventSource` polyfill advantage
  is forfeited deliberately.
- **Deployment**: any reverse proxy must disable response buffering for `text/event-stream`
  (`proxy_buffering off` / `X-Accel-Buffering: no`); `/readyz` must include a warmed verifier, and a
  chat-provider outage must **not** make the app unready — it makes answers fail visibly.
- **Data model** ([Specify the Postgres data model](https://github.com/mobley-trent/genweaver/issues/12)):
  `answers` needs `status in (complete, interrupted)`, an idempotency key unique per Account with a
  24-hour retention, and citation rows that snapshot document title, page ordinals and the matched
  quote so a deleted source still renders.
- **UI** ([Decide the minimal UI scope](https://github.com/mobley-trent/genweaver/issues/16)) inherits
  the event order, the pending-until-verdicts citation rule, and the `interrupted` and `unverified`
  states as distinct renderings rather than as errors.
- Two throttles are visible to clients: 409 `answer_in_progress` (one in-flight answer per
  conversation) and 429 `rate_limited` (two concurrent answers per Account), both carrying the id or
  `Retry-After` that makes them actionable.
- Money is integer micro-USD on the wire and never formatted server-side; the client renders currency
  and the band word, never the base float.
- The contract is maintained in one place — the issue resolution — with OpenAPI generated from models
  once code exists. There is no hand-written API document to drift.
- Ingestion `POST /documents/{id}/retry` and account retention stay separable: retry re-runs a failed
  ingestion, and reindexing remains [ADR 0014](./0014-reindex-builds-beside-the-serving-index.md)'s
  decision rather than an endpoint invented here.

## Amendment — 2026-11-24: readiness includes the retrieval alias

[ADR 0014](./0014-reindex-builds-beside-the-serving-index.md) made retrieval read one alias,
`chunks_current`, rather than a physical collection, so the contract above gains one clause: `/readyz`
answers 200 only when that alias resolves. Reachable Qdrant is no longer sufficient on its own —
reachable Qdrant with no alias is a deployment where every question is a miss, which is exactly the
state readiness exists to refuse.

`/healthz` is unchanged: the alias is a dependency, not the process, and liveness still touches nothing.
Readiness stays a boolean over the dependencies and the warm verifier — an in-flight reindex leaves it
green, because the deployment is fully serving on the collection it already points at.
