# DP Empty-Overage Compatibility Forward-Fix

Clone-only evidence 2026-09-15: base 72/88 plus additive `20260915100000` installed;
Production/client untouched. Apply this repair after unit 72 in rehearsal replay,
not by timestamp-only db push. No applied migration is edited.

Impact: valid DOWN_PAYMENT sets overage GUC empty before inner core, preventing
REGULAR-only trigger from running on DP. REGULAR, malformed/nonempty DP rejection,
delivery fee restrictions, locks, cleanup, audit, allocation, Stock/FIFO, Payment,
session and Finance effects unchanged. No existing data or history backfill.

1. [Read-only preflight](../../supabase/diagnostics/backoffice_invoice_dp_empty_overage_preflight.sql)
2. [Guarded migration](../../supabase/migrations/20260915100000_backoffice_invoice_dp_empty_overage_forward_fix.sql)
3. [Canonical rollback behavioral](../../supabase/tests/backoffice_sales_order_invoice_status_rehearsal_behavior.sql)
4. [Read-only postflight](../../supabase/diagnostics/backoffice_invoice_dp_empty_overage_postflight.sql)

Preflight four PASS, migration succeeds, postflight three PASS. Canonical rollback
behavior now PASS 18 scenarios, including valid DP/Regular posting, journals,
real-row DNI exit and posting retry. Second Company has no VIEW capability:
test asserts permission denial using canonical resolution, never bypasses guard.
C2B eleven and C3 twelve rollback scenarios PASS. Authenticated UI E2E/UAT and
full concurrency/role matrix remain pending. Fixtures roll back; sequences may advance.

Any error before commit rolls back function change. After installation use new
additive forward-fix, never reintroduce unconditional DP marker or disable guards.
