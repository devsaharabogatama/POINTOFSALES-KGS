# G6 Phase 8E — Purchase/AP Controlled Queue

Status: local-ready; manual Supabase rollout pending. This phase installs queue
authority only. It does not create a queue or post historical events.

## Execution order

1. Run `supabase/migrations/20260814150000_g6_phase8e_purchase_ap_controlled_queue.sql`.
2. Run `supabase/diagnostics/g6_phase8e_purchase_ap_controlled_queue_postflight.sql`.
3. Run `supabase/tests/g6_phase8e_purchase_ap_controlled_queue_tests.sql`.
4. Send the complete outputs. Do not run a live queue yet.

## Controlled live operation

After migration, postflight, and behavioral test are all confirmed PASS:

1. Run `supabase/operations/g6_phase8e_post_live_purchase_ap.sql` exactly once.
2. The returned run must be `COMPLETED`, preview `9`, posted `8`, failed `0`,
   skipped `1`.
3. Immediately run
   `supabase/diagnostics/g6_phase8e_purchase_ap_live_reconciliation_postflight.sql`.
4. Send the operation row and every postflight row.

The operation aborts and rolls back if the live scope is no longer exactly one
Company with 4 Goods Receipts, 3 Supplier Invoices, 2 Supplier Payments, and one
fully verified zero-value Receipt.

## Expected behavior

- Preview contains the final Goods Receipt, Supplier Invoice, and Supplier
  Payment `HOLD` events for the active Company only.
- Approval reuses the existing immutable preview/version guard.
- Positive effects become balanced, source-linked, idempotent Journals.
- A fully rejected or otherwise exact Rp0 Goods Receipt becomes
  `CANCELED / NO_FINANCIAL_EFFECT`; its queue item is `SKIPPED`, not failed,
  and no zero-value Journal is manufactured.
- The behavioral file rolls back all queue, Event, and Journal effects.

## Forward-fix boundary

If migration, postflight, or behavioral test fails, stop. Do not edit an applied
migration and do not create or process a live queue. Add a later forward-fix
migration after diagnosing the exact failing invariant.
