# SO Invoice Status — Clone Rehearsal

## Latest checkpoint

Superseding result: canonical 18-scenario rollback fixture PASS, Company-2
resolved no-VIEW denial asserted without permission bypass. Integrated WALK-IN
payment fixture 22 PASS after installing missing139000. Prior failures below are
historical, not the current status. Production/browser UAT still pending; see
[final clone report](OFFICE_PURCHASE_CLONE_REHEARSAL_FINAL_REPORT.md).

DP compatibility fix `20260915100000` now applied on clone; its gates PASS. Test
progresses through DP/Regular posting and real DNI exit, then fails on Company-2
VIEW permission. Full behavioral still NOT PASS; earlier DP failure below is
historical. Permission resolution audit is next; fixture document rows rollback
to zero. See [forward-fix evidence](BACKOFFICE_INVOICE_DP_EMPTY_OVERAGE_FORWARD_FIX.md).

## 2026-09-15 status

Clone `idrufihckscppsyclmsu` only. Unit 72 migration installed; preflight and
postflight five PASS each. Behavioral NOT PASS; Production/client untouched.

User approved completing rollback-only requirements. New fixture reuses the
canonical Invoice posting behavior and adds SO summary/status/filter/link and
real-row DNI checks. Old existing-SO reconciliation test remains unchanged.

- [Canonical rollback fixture](../../supabase/tests/backoffice_sales_order_invoice_status_rehearsal_behavior.sql)
- [Read-only failure inventory](../../supabase/diagnostics/backoffice_sales_order_invoice_status_rehearsal_failure_inventory.sql)

Test fails creating valid DOWN_PAYMENT Draft with
BACKOFFICE_ACCEPTED_OVERAGE_INVOICE_PAYLOAD_INVALID. Active core writes [] to the
accepted-overage input setting; trigger rejects non-REGULAR invoices whenever
input setting is present. Actual catalog flags corroborate this conflict.
SO/DO/Receipt/Invoice counts are zero after rollback; sequences may advance.

Next: impact-first DP/overage call-chain audit and additive forward-fix with
guards and regression tests. Never disable the trigger or modify applied
migrations. Do not continue rollout or claim status/report readiness from
zero-row postflight. Authenticated UI smoke and full UAT remain pending.
