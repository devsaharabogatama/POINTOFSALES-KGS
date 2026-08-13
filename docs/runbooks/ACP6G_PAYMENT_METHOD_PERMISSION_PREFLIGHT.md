# ACP-6G Payment Method Permission Preflight

## Scope

This is a `SELECT-only` diagnosis for `finance.payment_methods`. It checks:

- canonical Payment Method, Store assignment, audit, and save-RPC state;
- default, active period, Store eligibility, route, fee, and Account Function
  readiness;
- immutable system-owned Customer Balance/Ketul Offset boundaries;
- Sales payment snapshot, tenant, audit, privilege, and override integrity;
- separation from POS online/offline, Expense, Supplier Payment, and Finance
  Journal authority;
- composed Backoffice read, export, and optional future import target state.

It does not change schema, data, grants, RLS, RPC, API, UI, Sales, Expense,
Supplier Payment, Offline policy, Financial Event, or Journal runtime.

## Manual step

Run the complete file in Supabase SQL Editor:

`supabase/diagnostics/acp_phase6g_payment_method_permission_preflight.sql`

Send every returned row as `check_name,status,details`.

## Interpretation

- `BLOCKER`: stop. The named live invariant must be corrected before ACP-6G.
- `BACKFILL`: stop and review exact scope before any write.
- `PASS`: existing invariant is ready.
- `REVIEW`: approved boundary the cutover must preserve; it is not a failure.
- `SETUP`: expected enforcement target is not present yet; it is not a failure.
- `INFO`: inventory only.

Do not run a migration from another ACP phase and do not edit an already
applied migration. ACP-6G enforcement is designed only after this live output
has no unresolved blocker/backfill.
