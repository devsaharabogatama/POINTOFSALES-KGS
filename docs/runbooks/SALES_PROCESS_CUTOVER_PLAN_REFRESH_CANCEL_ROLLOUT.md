# Sales Process Cutover Plan Refresh/Cancel Rollout

**Current step:** 1C/6. **Target:** isolated Development `fkywtxucmyjvpwdiqpix`.
Production/staging must not be used.

**Live status:** migration + postflight + behavioral rollback user-confirmed
PASS on isolated Development.

Migration `20260910120000` adds optimistic `master_version` to cutover plans,
Super Admin refresh, and audited cancel. Refresh replaces only candidate items
and preview facts using current source versions. Target mode, effective time,
and reason remain locked. To change them, cancel the plan and create a new one.

Cancel retains plan/items/audit as history. Neither operation applies a mode
switch or mutates Order, Revision, Reservation, PO, Dispatch, Stock/FIFO,
Invoice, Payment, Finance, Offline submission, or Company entitlement.

Run in order:

1. [Preflight](../../supabase/diagnostics/sales_process_cutover_plan_refresh_cancel_preflight.sql)
2. [Migration](../../supabase/migrations/20260910120000_sales_process_cutover_plan_refresh_cancel.sql)
3. [Behavior](../../supabase/tests/sales_process_cutover_plan_refresh_cancel_behavior.sql)
4. [Postflight](../../supabase/diagnostics/sales_process_cutover_plan_refresh_cancel_postflight.sql)

Stop on SQL error, `BLOCKER`, or `FAIL`. Apply/conversion/switch remains closed.
