# Auth options for genweaver

Evidence behind [ADR 0005](../adr/0005-accounts-are-invite-only-and-auth-runs-in-the-app.md), which resolved [Choose the auth mechanism for invite-gated accounts](https://github.com/mobley-trent/genweaver/issues/9). Facts retrieved 2026-11-24. Prices, tiers and versions move; re-check before quoting a number.

## The constraint

Three requirements do the deciding:

1. **Local-first.** A fresh clone must reach a working, signed-in session with `docker compose up` — no vendor account, no egress to an identity provider, no second auth path for the demo.
2. **Invite-only and public-facing.** Accounts come into existence only by invitation, so open registration is a route a provider cannot own for us.
3. **Postgres is already running.** Session and invite state has a home before a single service is added.

## Managed identity providers

| Provider | Self-hostable | Free tier | First paid tier | Consequence |
| --- | --- | --- | --- | --- |
| **Clerk** | **No** — managed SaaS; no self-host option, backend proprietary ([pricing article](https://clerk.com/articles/clerk-pricing-explained)) | 50,000 MRU/app; 7-day fixed session lifetime; no MFA ([pricing](https://clerk.com/pricing)) | Pro $25/mo (50k MRU), then $0.02/MRU | Cannot sign in offline. Breaks requirement 1 outright |
| **Auth0** | **No** — Public Cloud or *managed* Private Cloud only; no customer-run install ([deployment options](https://auth0.com/docs/deploy-monitor/deployment-options)) | 25,000 MAU; 1 custom domain; 1 enterprise connection ([pricing](https://auth0.com/pricing)) | B2C Essentials $35/mo at 500 MAU; Professional $240/mo | Same failure as Clerk, with a steeper first paid tier |
| **Supabase Auth (GoTrue)** | **Yes** — MIT-licensed Go auth server over Postgres ([repo](https://github.com/supabase/auth), [self-hosting auth](https://supabase.com/docs/reference/self-hosting-auth/introduction)) | 50,000 MAU ([pricing](https://supabase.com/pricing)) | Pro $25/mo, then $0.00325/MAU | Viable but heavy: the full self-hosted stack is ~11 containers / 4 GB / 2 cores ([requirements](https://supabase.com/docs/guides/self-hosting/docker)). Invite-link single-use and expiry semantics are undocumented |

A managed provider buys the session plumbing and a hosted login UI, but not the part this project actually needs: invites, revocation, and a tenant mapping. It also splits the deployment into "works with network" and "does not".

## Self-hostable auth servers

| Server | License | Services added | Native invite-only registration | Operating cost |
| --- | --- | --- | --- | --- |
| **authentik** | Core MIT ([pricing](https://goauthentik.io/pricing)) | Postgres + server + worker; no Redis since 2025.10 ([install](https://docs.goauthentik.io/docs/install-config/install/docker-compose/)) | **Yes** — Invitation stage with `single_use` and `expires` (48 h default) ([invitations](https://docs.goauthentik.io/users-sources/user/invitations)) | ~2 CPU / 2 GB ([install](https://docs.goauthentik.io/docs/install-config/install/docker-compose/)) |
| **Keycloak** | Apache-2.0 ([LICENSE](https://github.com/keycloak/keycloak/blob/main/LICENSE.txt)) | Keycloak + Postgres ([db guide](https://www.keycloak.org/server/db)) | Only by disabling self-registration and using admin `invite-user` action tokens ([admin guide](https://www.keycloak.org/docs/latest/server_admin/index.html)) | ~2 GB recommended ([containers](https://www.keycloak.org/server/containers)) |
| **ZITADEL** | AGPL-3.0-only since v3 ([LICENSING.md](https://github.com/zitadel/zitadel/blob/main/LICENSING.md)) | Traefik + API + Login UI + Postgres ([compose](https://zitadel.com/docs/self-hosting/deploy/compose)) | Yes — invite code, 6 chars, 72 h expiry ([invite code](https://zitadel.com/docs/apis/resources/user_service_v2/user-service-create-invite-code)) | 2 GB host; AGPL network-disclosure obligations |
| **Ory Kratos** | Apache-2.0 ([license options](https://www.ory.com/self-hosted-license-options)) | Kratos + Postgres; you build every UI | No native invitation object; a before-registration hook ([actions](https://www.ory.com/docs/kratos/hooks/configure-hooks)) | Headless: all login UI is ours anyway |

Every one of them is a second Postgres-backed service wanting ~2 GB, an upgrade treadmill and a browser redirect flow — to own a problem the app must solve itself regardless, because invites and the tenant mapping live in our schema either way.

## In-app auth

The route taken. `pwdlib[argon2]` for hashing, opaque session rows in the Postgres already in the compose file, invites as rows, and a FastAPI dependency for the authenticated user. The compose file stays app + Postgres + Qdrant, and `docker compose up` works with no network.

### Sessions

| Topic | Guidance | Source |
| --- | --- | --- |
| Token entropy | CSPRNG, ≥ 128 bits (ASVS 7.2.3); 160+ preferred for credentials | [ASVS 5.0 V7](https://github.com/OWASP/ASVS/blob/master/5.0/en/0x16-V7-Session-Management.md), [OWASP Session Management](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html) |
| At rest | Store a fast hash (SHA-256) of a high-entropy token, never the raw value; constant-time compare | [OWASP Session Management](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html) |
| Cookie | `Secure` mandatory, `HttpOnly` mandatory, `SameSite=Strict` preferred / `Lax` acceptable, `__Host-` prefix, no `Domain` | [OWASP Session Management](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html) |
| FastAPI defaults | `Response.set_cookie` defaults to `secure=False, httponly=False, samesite="lax"` — all three must be set explicitly | [FastAPI Response](https://fastapi.tiangolo.com/reference/response) |
| Rotation | New token on authentication (including re-auth); terminate the old one (ASVS 7.2.4) | [ASVS 5.0 V7](https://github.com/OWASP/ASVS/blob/master/5.0/en/0x16-V7-Session-Management.md) |
| Timeouts | Idle **15–30 min** for low-risk, **2–5 min** high-value; absolute **4–8 h**; enforced server-side (ASVS 7.3.1/7.3.2) | [OWASP Session Management](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html), [NIST 800-63B](https://pages.nist.gov/800-63-4/sp800-63b/session) |
| CSRF | Cookie auth requires CSRF defence; SameSite is **defence in depth, not a replacement** for a token | [OWASP CSRF](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html), [OWASP FastAPI](https://cheatsheetseries.owasp.org/cheatsheets/FastAPI_Security_Cheat_Sheet.html) |

### Password hashing

OWASP's current floor is Argon2id with **19 MiB memory, t=2, p=1** (equivalently 46 MiB/t=1, or 12 MiB/t=3) ([Password Storage](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html)).

| Library | Status | Note |
| --- | --- | --- |
| `argon2-cffi` | Maintained (25.1.0) ([repo](https://github.com/hynek/argon2-cffi)) | Library defaults are **64 MiB, t=3, p=4** — stronger, and heavier on a laptop ([API](https://argon2-cffi.readthedocs.io/en/stable/api.html)) |
| `pwdlib` | Maintained (0.4.2) ([PyPI](https://pypi.org/project/pwdlib)) | Thin wrapper over argon2-cffi; exists because passlib is stale |
| `passlib` | **Not maintained**; breaks on Python 3.13 ([rationale](https://frankie567.github.io/pwdlib)) | Avoid for new code |

### Invites

Random token (≥ 128 bits, `secrets.token_urlsafe(32)`), **hash at rest**, explicit short expiry, single use, consumed atomically ([OWASP Forgot Password](https://cheatsheetseries.owasp.org/cheatsheets/Forgot_Password_Cheat_Sheet.html)). `UPDATE … RETURNING` gives consume-if-unused in one statement, with no read-then-write race ([PostgreSQL docs](https://www.postgresql.org/docs/current/dml-returning.html)).

### Frameworks considered and rejected

- **`fastapi-users`** — in maintenance mode since 2025-10-25 (security and dependency updates only) ([discussion](https://github.com/fastapi-users/fastapi-users/discussions/1543)). Its database strategy stores the **raw** token, supports only an absolute lifetime, and has no rotation or hashing at rest; it also ships an open `/register` route that invite-gating would have to replace ([authentication](https://fastapi-users.github.io/fastapi-users/latest/configuration/authentication), [database strategy](https://fastapi-users.github.io/fastapi-users/latest/configuration/authentication/strategies/database/)).
- **`fastapi-fullauth`** — MIT and active, but a single-maintainer, young project; unaudited here.
- **A self-hosted auth server** — see above: ~2 GB and a redirect flow for a login form we need anyway.

## Sources

- OWASP ASVS 5.0, V7 Session Management — <https://github.com/OWASP/ASVS/blob/master/5.0/en/0x16-V7-Session-Management.md>
- OWASP Session Management Cheat Sheet — <https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html>
- OWASP Password Storage Cheat Sheet — <https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html>
- OWASP CSRF Prevention Cheat Sheet — <https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html>
- OWASP Forgot Password Cheat Sheet — <https://cheatsheetseries.owasp.org/cheatsheets/Forgot_Password_Cheat_Sheet.html>
- OWASP FastAPI Security Cheat Sheet — <https://cheatsheetseries.owasp.org/cheatsheets/FastAPI_Security_Cheat_Sheet.html>
- NIST SP 800-63B, session management — <https://pages.nist.gov/800-63-4/sp800-63b/session>
- FastAPI, `Response` reference — <https://fastapi.tiangolo.com/reference/response>
- Clerk pricing / self-hosting — <https://clerk.com/pricing>, <https://clerk.com/articles/clerk-pricing-explained>
- Auth0 deployment options / pricing — <https://auth0.com/docs/deploy-monitor/deployment-options>, <https://auth0.com/pricing>
- Supabase self-hosting — <https://supabase.com/docs/guides/self-hosting/docker>, <https://supabase.com/docs/reference/self-hosting-auth/introduction>
- authentik invitations — <https://docs.goauthentik.io/users-sources/user/invitations>
- Keycloak admin guide — <https://www.keycloak.org/docs/latest/server_admin/index.html>
- ZITADEL licensing / invite codes — <https://github.com/zitadel/zitadel/blob/main/LICENSING.md>, <https://zitadel.com/docs/apis/resources/user_service_v2/user-service-create-invite-code>
- argon2-cffi — <https://argon2-cffi.readthedocs.io/en/stable/api.html>
- pwdlib rationale — <https://frankie567.github.io/pwdlib>
- fastapi-users maintenance mode — <https://github.com/fastapi-users/fastapi-users/discussions/1543>

## What could not be verified

- **Supabase GoTrue invite links**: whether a token is strictly single-use, and its default TTL. The docs describe `inviteUserByEmail()` and `GOTRUE_DISABLE_SIGNUP` but state neither ([users](https://supabase.com/docs/guides/auth/users), [config](https://supabase.com/docs/guides/self-hosting/auth/config)). One reason not to specify behaviour we cannot check.
- **The OWASP Password Storage page's revision date**: the 19 MiB/t=2/p=1 profile is on the live page, but the page carries no visible revision date in the extracted text.
- **Keycloak's 12 h admin-initiated action-token default** comes from a third-party write-up, not keycloak.org.
- **authentik's MIT core licensing** is confirmed via secondary summaries of the split licence, not the LICENSE file itself.
- **The real cost of argon2 at the 19 MiB floor on the target hardware** — unmeasured. The library's 64 MiB default is the known-good performance point, so a login-latency measurement belongs in the deployment runbook.
