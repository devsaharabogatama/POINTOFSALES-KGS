# ACP-6G Payment Method Permission Enforcement

## Scope

- composed Backoffice read guarded by `finance.payment_methods VIEW`;
- ordinary Payment Method mutation guarded by `MANAGE`;
- separate open-session POS and Expense `POST` reference RPCs;
- CSV export guarded independently by `EXPORT`;
- truthful `BACKFILL` audit rows for legacy/provisioned methods;
- direct browser read closure for Method, Store assignment, and audit tables.

This rollout does not open Payment Method import, allow generic mutation of
Customer Balance/Ketul Offset, change checkout pricing/payment effects, merge
Supplier Payment enums, process Financial Events, or post Journals.

## Manual order

Stop immediately on SQL error or postflight `FAIL`.

1. Run [migration](../../../supabase/migrations/20260813130000_acp_phase6g_payment_method_permission_enforcement.sql).
2. Restart Backoffice and PWA so PostgREST/client caches are refreshed.
3. Run [postflight](../../../supabase/diagnostics/acp_phase6g_payment_method_permission_postflight.sql).
4. Run [behavior test](../../../supabase/tests/acp_phase6g_payment_method_permission_tests.sql).
5. Run regressions:
   - `supabase/tests/g2_phase14_payment_method_foundation_tests.sql`
   - `supabase/tests/g2_phase36_automatic_master_codes_tests.sql`
   - `supabase/tests/g4_phase8_payment_leg_identity_tests.sql`
   - `supabase/tests/acp_phase6a_expense_permission_tests.sql`
6. Rerun ACP-6G postflight.

## Expected

- no postflight `FAIL`;
- permission status `ENFORCED`;
- both save overloads contain effective `MANAGE` guard;
- Backoffice response includes methods, assignments, Stores and audit proof;
- POS list works only for the caller's open Cashier session and Store;
- Expense reference requires its own `POST` authority;
- authenticated has no direct read/write on the three dedicated tables;
- every current Payment Method has at least one audit row;
- existing Sale/payment snapshots remain valid.

## Authenticated smoke (closing UAT allowed)

- Owner/Admin/Finance: list and export; only effective `MANAGE` users see edit;
- Accounting and `LIHAT_SAJA`: list only, no mutation/export;
- switch Company and confirm Method/Store/audit isolation;
- POS cashier reloads catalog and sees only active Store-eligible methods;
- online checkout and split payment still post successfully;
- non-cash Expense return still validates the selected active reference;
- Customer Balance/Ketul Offset cannot be edited from generic master UI.

Applied migration files are immutable. Any live failure must use a higher
versioned forward-fix and update the handoff/manifest.
