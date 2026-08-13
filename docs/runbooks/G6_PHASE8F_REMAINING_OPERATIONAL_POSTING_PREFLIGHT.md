# G6 Phase 8F — Remaining Operational Posting Preflight

Status: SELECT-only diagnostic local-ready. No schema, Event, Journal, queue, or
business data is changed.

Run:

`supabase/diagnostics/g6_phase8f_remaining_operational_posting_preflight.sql`

Send every result row. Expected inventory is two Stock Gain, two Expense
Disbursement, two Cash Deposit, and one Cash Variance event. Every `BLOCKER`
must be zero before runtime work starts.

The preflight verifies final source linkage, exact amount snapshots, account
snapshots, postable period availability, no existing Journal, and no active
Finance queue. Runtime will remain contract-separated even though discovery is
combined: Stock Gain first, then Expense Disbursement, Cash Deposit, and Cash
Variance.
