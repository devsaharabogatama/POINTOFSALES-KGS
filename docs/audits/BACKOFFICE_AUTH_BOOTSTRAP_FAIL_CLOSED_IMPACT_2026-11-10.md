# Backoffice Auth Bootstrap Fail-Closed Impact Audit

**Date:** 2026-11-10  
**Classification:** `PRODUCT_BEHAVIOR_CHANGE`  
**Target:** Backoffice client bootstrap only  
**Database / Production mutation:** none

## Expected outcome and source of truth

After the Supabase session check completes, Backoffice must either show the
authenticated Company workspace or return control to a usable login/error
state. A rejected or indefinitely pending session check must not leave the user
on `Menyiapkan backoffice` forever. Authentication and Company authorization
remain server-authoritative.

Sources read:

- root `AGENTS.md` instructions supplied for this repository;
- `backoffice/AGENTS.md`;
- `docs/AI_AGENT_CONTINUATION_PLAYBOOK.md`;
- `docs/README.md`, `docs/POS_V1_MVP_REQUIREMENT_INDEX.md`, and the active
  local/authenticated-smoke entries in `docs/POS_V1_IMPLEMENTATION_GATES.md`;
- Next.js 16 bundled authentication and environment-variable guides;
- `backoffice/src/app/page.tsx` and `backoffice/src/lib/supabase.ts`;
- `backoffice/src/app/api/me/context/route.ts` and
  `backoffice/src/lib/server-auth.ts`;
- `scripts/run-production-shaped-local.ps1` and
  `docs/runbooks/BACKOFFICE_SALES_LOCAL_ENVIRONMENT.md`.

## Proven active execution path

1. `backoffice/src/app/page.tsx:240-254` calls
   `supabase.auth.getSession()` and subscribes to `onAuthStateChange`.
2. `checkingSession` is cleared only inside the fulfilled `getSession().then`
   handler or an auth-state callback. There is no rejection, timeout, or
   unmount guard for the initial promise.
3. While `checkingSession` remains true,
   `backoffice/src/app/page.tsx:728-729` renders only
   `Menyiapkan backoffice`.
4. Once a session is available, `loadContext` calls
   `GET /api/me/context` with the bearer token.
5. `backoffice/src/app/api/me/context/route.ts` calls `requireCaller`, reads the
   Profile and active Company, then returns the authorized Company list.
6. `backoffice/src/lib/server-auth.ts` validates the bearer token through
   Supabase Auth. Direct table privileges are not widened by this client fix.

## Runtime/database state

- Local Supabase target is guarded at `http://127.0.0.1:54321`.
- Official local authenticated smoke reports Auth, Company isolation, Retail
  bootstrap/catalog, and Backoffice references `PASS`.
- Direct `GET /api/me/context` has returned HTTP 200 with the local fixture.
- The browser screenshot proves the client can remain on the initial loader for
  more than ten minutes.
- Earlier browser evidence also captured a transient `JWT issued at future`
  response immediately after login. Container and Windows clocks were later
  measured in the same second, so a persistent large clock skew is not proven.
- Browser traces proved both mixed-host failure modes. `localhost:3000` calling
  `127.0.0.1:54321` triggers Chromium loopback cross-host preflight failures;
  changing Supabase to `localhost:54321` instead produces
  `ERR_CONNECTION_RESET` because this Docker binding is only proven on IPv4
  loopback. Next.js separately logged that `127.0.0.1` dev resources require an
  explicit `allowedDevOrigins` entry. The evidence-backed pair is therefore
  `127.0.0.1:3000` -> `127.0.0.1:54321`, with a narrow Next dev-origin allowlist.
- Migration state is unchanged; this task has no migration.
- Fresh-profile Chromium smoke on the canonical `127.0.0.1` pair proved the
  exact transient sequence: Auth token HTTP 200, first `/api/me/context` HTTP
  500 `JWT issued at future`, manual retry HTTP 200, then Company workspace.
  The implementation may therefore retry exactly that error once after a
  bounded delay; it must not retry or accept any other JWT error.

## Impact map

### Direct impact

- initial client-side session bootstrap;
- login screen error/retry presentation;
- cleanup when the component unmounts.

### Downstream consumers

- `/api/me/context` and active-Company selection are invoked only after a valid
  session and retain their current contracts;
- tenant navigation, permissions, Finance, Sales, Inventory, Stock/FIFO,
  Payment, Cashier Session, and audit consumers are not changed;
- logout and `onAuthStateChange` must continue clearing tenant state.

### Compatibility

- valid stored sessions must still open the same workspace;
- no-session users must still see Login;
- invalid/expired sessions must still be signed out by the existing context
  guard;
- no keys, tokens, service-role values, or database objects are added;
- hosted and local environments use the same bounded client behavior.

### Concurrency, retry, idempotency, rollback

- bootstrap may run concurrently with the first auth-state callback; completion
  must be idempotent and must not restore stale state after unmount;
- no automatic login or database mutation is introduced;
- a bounded client timeout only releases the loader and exposes retry/login;
- rollback is a source revert because there is no schema or data effect.

## Regression matrix

| Scenario | Expected |
|---|---|
| No stored session | Login renders; no infinite loader |
| Valid stored session | Context loads and Company workspace renders |
| Fresh password login | Auth event leads to context/workspace |
| Session lookup rejects | Loader ends and actionable error is shown |
| Session lookup never settles | Bounded timeout ends loader |
| Invalid context token | Existing local sign-out path remains |
| Logout | Session, context, and Company state are cleared |
| Multi-Company actor | Existing active-Company selection is preserved |
| Local canonical URL | `127.0.0.1:3000` calls `127.0.0.1:54321`; Next allowlist is loopback-only |
| Mixed `localhost` / `127.0.0.1` | Runbook rejects mixed hosts; browser failure is not hidden |

## Unknowns and design boundary

- The exact browser-internal reason that left `getSession()` pending is not yet
  observable because the native browser-control bridge is unavailable.
- That unknown does not change the required fail-closed design: no external
  dependency may leave the application in an unbounded loader.
- This patch must not add server-side JWT tolerance, weaken token validation,
  modify Finance behavior, or touch Production.

## Verification required after implementation

1. focused lint/typecheck for changed client code;
2. production build;
3. official authenticated local API smoke;
4. automated real-browser login/bootstrap smoke where tooling permits;
5. user visual confirmation; until then status is not `UAT PASS`.

## Verification result

- focused ESLint: PASS;
- Next.js production build and TypeScript: PASS;
- official guarded local authenticated API smoke: PASS;
- fresh-profile Chromium login/bootstrap: PASS to Company workspace;
- observed transient: first context HTTP 500 `JWT issued at future`, followed
  by the single exact-error auto-retry HTTP 200;
- Production access/deployment: none;
- user visual UAT: pending.
