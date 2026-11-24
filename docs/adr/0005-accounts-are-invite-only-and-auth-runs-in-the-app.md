# Accounts are invite-only, and auth runs in the app

**Status:** accepted

Authentication is part of the application, not a service beside it. A person arrives through an **Invite** — a single-use, expiring, hashed token an **Admin** issued — redeems it with an email and a password, and receives an opaque **Session** recorded in the same Postgres that holds everything else. Passwords are argon2id at OWASP's 19 MiB floor through `pwdlib`. The user id **is** the tenant id.

The deciding constraint is the one the whole project is built on: `clone → env → docker compose up` has to produce a working, signed-in app. Clerk and Auth0 cannot be self-hosted at all, so a managed provider would mean either a demo that cannot log in offline or a second self-hosted auth path beside it — two auth systems, one of them never exercised. A self-hosted auth server (authentik, Keycloak, GoTrue) is genuinely possible and would bring a hardened login UI, MFA and native invitations, but it costs a ~2 GB service, an upgrade treadmill and a browser redirect flow, and it still does not own the thing this project actually needs: the invitation record, its revocation, and the mapping from identity to tenant. Those live in our schema whichever option wins. So the provider question reduces to who writes the login form and the session table, and the answer is us.

**Sessions are server-side and opaque.** A 256-bit random token, stored only as its SHA-256 hash, rides in a `__Host-` cookie with `Secure`, `HttpOnly` and `SameSite=Lax`; a new token is issued at login and the old row terminated. The alternative — a signed JWT in the cookie — saves one query per request and forfeits revocation: logout, an admin terminating a compromised account, and "sign out everywhere" all become a revocation list, which is the session table with more steps. Timeouts are 60 minutes idle and 12 hours absolute, both enforced server-side. That is a **documented relaxation** of OWASP's 15–30 minute low-risk sample, chosen because a portfolio demo that logs its reviewer out mid-read is a worse artifact than one with a longer idle window; the number is a knob, not a principle.

**Invites are tokens, not pre-created accounts.** The admin mints one, sees it exactly once, and hands it over; the database keeps only its hash. Redemption is a single `UPDATE … WHERE token_hash = $1 AND used_at IS NULL AND revoked_at IS NULL AND expires_at > now() RETURNING …` inside the transaction that creates the user, so an invite cannot be spent twice and no row exists until it is spent. A pre-created user row would put an account in the data model before anyone had signed in, and every query downstream would need a "pending" filter. A short typeable code would be friendlier to read aloud and would rest entirely on its lockout being correct.

**There is no mail server.** With no SMTP in the compose file, an invite's email address is a binding label, not a verified identity: it scopes who the link was meant for, and the redemption endpoint refuses a different address, but nothing proves the holder owns that mailbox. The same is true of password resets, which are admin-issued one-time links rather than self-service email. This is the honest cost of local-first, and it must be stated rather than glossed as "email verification".

**Roles are two.** `admin` issues and revokes invites, terminates sessions, and re-issues credentials; `member` sees its own documents and answers and nothing else. The first admin comes from a CLI that refuses to run once any admin exists, so a fresh clone bootstraps without a hardcoded credential in the repo or the compose file.

## Considered Options

- **Managed identity provider (Clerk, Auth0)** — the least code and the best login UI, and unusable in the local compose; would either break the offline demo or add a second auth path.
- **Self-hosted auth server (authentik, Keycloak, ZITADEL, Ory, GoTrue)** — hardened auth, native invitations, future SSO; ~2 GB, an upgrade treadmill, a redirect flow, and our invite/tenant model still ours to write. Worth revisiting if SSO or MFA becomes a requirement, not before.
- **Stateless JWT cookie** — no session table, no query per request, and no way to revoke a token before it expires without the table it avoided.
- **Pre-created user rows with a set-password link** — the account exists before the person does; every downstream query inherits a pending state.
- **Short human-typeable invite codes** — friendlier to hand over verbally, materially weaker entropy, safety resting entirely on attempt limits.
- **`fastapi-users`** — in maintenance mode since October 2025, its database strategy stores raw tokens with no rotation or idle timeout, and it ships the open registration route invite-gating exists to prevent.
- **`passlib`** — unmaintained and broken on Python 3.13; `pwdlib` is the replacement.

## Consequences

- The app owns ~200 lines of session, invite and password code, and with it the reset flow, rotation and CSRF correctness. That is a real cost, paid in exchange for a compose file of three services and a demo that works offline.
- **No signing secret is required.** Opaque tokens need no key, and the CSRF token is random per response, so the environment carries no `AUTH_SECRET` to leak, rotate or forget to set.
- CSRF is defended with a double-submit token plus an `Origin`/`Host` equality check on unsafe methods; SameSite alone is explicitly not treated as sufficient.
- Login is throttled in Postgres — per (email, IP) failure counts with exponential backoff and a per-account lock — because the compose file ships no reverse proxy to do it and an in-process limiter silently stops working at the second worker.
- Authentication is **deny-by-default**: one router-level dependency resolves the session into a `CurrentUser`, with an explicit allowlist for login, invite redemption and health. A new route is private unless someone deliberately opens it.
- Password policy is NIST-shaped — 12 characters minimum, no composition rules, no forced rotation — and a change of argon2 parameters is a rehash on next login, not a migration, because hashes are stored as PHC strings.
- **New tables**: `users`, `sessions`, `invites`, `login_attempts`. Their shape belongs to [Specify the Postgres data model](https://github.com/mobley-trent/genweaver/issues/12).
- The session table makes revocation instant and makes the operator's obligations explicit: the runbook must cover minting and revoking invites, terminating a user's sessions, and re-issuing a password.
- **Deactivation is not settled by this.** Terminating sessions answers "stop using the deployment now"; what happens to that account's documents, chunks and answers is a separate decision, now its own ticket.
- With no email delivery, "verified account" is not a state this system has, and nothing in the product may imply it.

See [`docs/research/auth-options.md`](../research/auth-options.md) for the comparison and sources this rests on.

**Naming amendment (2026-11-24).** The table this ADR calls `users` is `accounts`, and `owner_id` on every tenant-scoped table references it. **Account** is the glossary's term and the only identity this system has; the decision above is unchanged. [ADR 0011](./0011-postgres-is-the-source-of-truth-and-history-is-a-snapshot.md) carries the schema.
