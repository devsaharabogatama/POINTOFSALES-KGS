# G6 Phase 8F — Remaining Operational Runtime

Status: local-ready; manual Supabase rollout pending. Migration installs posting
runtime only and leaves all seven historical events on `HOLD`.

Run in order:

1. `supabase/migrations/20260814160000_g6_phase8f_remaining_operational_posting_runtime.sql`
2. `supabase/diagnostics/g6_phase8f_remaining_operational_runtime_postflight.sql`
3. `supabase/tests/g6_phase8f_remaining_operational_runtime_tests.sql`
4. Rerun the postflight and send every result.

The behavioral test posts 2 Stock Gain, 2 Expense Disbursement, 2 Cash Deposit,
and 1 Cash Variance inside one rollback transaction. It verifies exact Journal
identity, source accounts and amounts, balance, and idempotent replay. Do not
open a live queue until every step passes.

Any applied-file correction must be a later forward-fix migration. Never edit
this migration after rollout and never patch Event/Journal rows directly.
