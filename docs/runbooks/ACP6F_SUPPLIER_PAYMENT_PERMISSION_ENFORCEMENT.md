# ACP-6F Supplier Payment Permission Enforcement

## Scope

Enforce only `finance.supplier_payments`:

- composed Backoffice list/detail/reference response guarded by `VIEW`;
- Draft create/edit, final validation, and Draft cancellation capabilities;
- server-validated active postable cash/bank source account;
- monthly XLSX export guarded independently by `EXPORT`;
- direct browser read closure for three dedicated payment relations;
- immutable validated AP settlement and Financial Event `HOLD` preservation.

This rollout does not add a review state, cancel validated payments, post a
Journal, alter Supplier Invoice matching, or enforce Payment Method permissions.

## Manual order

Stop immediately on SQL error or postflight `FAIL`.

1. Run migration:
   `supabase/migrations/20260813120000_acp_phase6f_supplier_payment_permission_enforcement.sql`
2. Restart Backoffice to clear schema/client cache.
3. Run postflight:
   `supabase/diagnostics/acp_phase6f_supplier_payment_permission_postflight.sql`
4. Run rollback-safe behavior:
   `supabase/tests/acp_phase6f_supplier_payment_permission_tests.sql`
5. Run regression:
   `supabase/tests/g5_phase14_supplier_payment_tests.sql`
6. Run Supplier Invoice consumer regression:
   `supabase/tests/acp_phase6e_supplier_invoice_permission_tests.sql`
7. Run G5 postflight:
   `supabase/diagnostics/g5_phase14_supplier_payment_postflight.sql`
8. Rerun ACP-6F postflight.

## Expected

- ACP-6F postflight has no `FAIL`;
- `finance.supplier_payments` is `ENFORCED`;
- three public mutation wrappers contain effective capability checks;
- cancellation wrapper rejects every non-Draft document;
- explicit account is validated again on Draft save and validation;
- authenticated has no direct read/write on the three payment tables;
- all existing Supplier Payment events remain `HOLD`;
- G5 payment and ACP-6E Invoice consumer regressions pass.

## Authenticated smoke (closing UAT allowed)

- Finance/Owner/Admin: list, create/edit Draft, validate, cancel Draft, export;
- Accounting: read/export only by baseline;
- `LIHAT_SAJA`: list/detail only, no Draft/Post/cancel/export;
- switch Company and confirm no payment, Invoice, Supplier, account, or actor
  from the previous Company appears;
- validate with eligible explicit source account and with blank fallback;
- confirm attempting to cancel a VALIDATED payment fails immutable.

## Compatibility and forward-fix

The proven G5 transaction bodies are preserved as private cores. Do not edit an
applied migration. If live regression exposes an issue, add a higher-versioned
forward migration and record exact evidence in the handoff and manifest.
