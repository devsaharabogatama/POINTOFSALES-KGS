# G6 Phase 8G — Remaining Operational Controlled Queue

Status: local-ready; live posting remains closed.

Run in order:

1. `supabase/migrations/20260814170000_g6_phase8g_remaining_operational_controlled_queue.sql`
2. `supabase/diagnostics/g6_phase8g_remaining_operational_queue_postflight.sql`
3. `supabase/tests/g6_phase8g_remaining_operational_queue_tests.sql`
4. Rerun the postflight and send all rows.

Migration posts nothing. Behavioral previews, approves, and processes exactly
seven events inside a rollback transaction. Expected result is `COMPLETED`,
posted 7, failed 0, skipped 0. Live operation is created only after this gate
passes.

## Final controlled live operation

After migration, postflight, behavioral, and repeated postflight are confirmed
PASS:

1. Run `supabase/operations/g6_phase8g_post_live_remaining_operational.sql`
   exactly once.
2. Require `COMPLETED`, preview `7`, posted `7`, failed `0`, skipped `0`.
3. Immediately run
   `supabase/diagnostics/g6_phase8h_finance_historical_closure_postflight.sql`.
4. Send the operation row and every closure row.

The live operation rolls back unless its scope remains exactly one Company with
2 Stock Gain, 2 Expense Disbursement, 2 Cash Deposit, and 1 Cash Variance.
