# Backoffice AR Reversal Consumer Parity Audit — 2026-11-10

## Classification and scope

- Task classification: `SCHEMA_OR_MIGRATION_CHANGE` / `PRODUCT FIX`.
- Environment audited: local production-shaped Supabase only.
- Production access or mutation: none.
- Expected outcome: reversing an explicit Backoffice Credit Note allocation must restore the target Invoice receivable in every AR consumer, while preserving the append-only allocation and reversal ledger.

## Source of truth and identifiers

| Identifier | Defining source / evidence |
| --- | --- |
| `private.ar4_backoffice_invoice_allocated_credit(uuid,uuid,date)` | `supabase/migrations/20261105120000_backoffice_ar_credit_note_open_credit_runtime.sql:91` |
| `private.ar5_item_allocated(uuid,uuid,date)` and reversal sign | `supabase/migrations/20261106100000_backoffice_ar_open_credit_actions.sql:70` |
| `public.ar_open_item_allocations.reversal_of_allocation_id` | `supabase/migrations/20261106100000_backoffice_ar_open_credit_actions.sql` |
| `public.get_finance_ar_aging(date,uuid,uuid)` | active local definition and Task 4 patch at `supabase/migrations/20261105120000_backoffice_ar_credit_note_open_credit_runtime.sql:258` |
| Backoffice Invoice schedule | `public.backoffice_sales_invoice_receivable_schedules`, proven from local `information_schema` |
| Replacement Invoice lineage | `public.backoffice_sales_invoices.replacement_credit_note_id` and `replacement_source_invoice_id`, defined by `supabase/migrations/20261110100000_backoffice_ar_credit_note_replacement_invoice.sql` |

## Production runtime-anchor divergence

After Task 6 closed, the Production parity preflight reports every dependency,
installation and runtime-boundary check PASS, but the active
`private.ar5_item_allocated(uuid,uuid,date)` digest is
`63d4690aa26036ab394907255d121a42` instead of the defining Task 5 digest
`3de3fd3ba6aa98e79db22ef32f1bd0da`. The shared Task 4 helper remains exact,
not reversal-aware, and still has seven consumers. Parity migration remains
fail-closed and must not run.

Local evidence disproves a simple CRLF explanation: canonical local LF is the
expected digest, while simulated CRLF is
`976afa4d7810f82c66474bcd43607cbd`, not the Production digest. Exact active
Production definition and routine attributes are therefore `BELUM TERBUKTI`.
The SELECT-only evidence file is
`supabase/diagnostics/backoffice_ar_reversal_helper_definition_diagnosis.sql`.

Production definition evidence closes the unknown: raw digest is the reported
`63d4690aa26036ab394907255d121a42`, with 10 mixed CRLF boundaries, while
CRLF-to-LF normalization is exactly the canonical
`3de3fd3ba6aa98e79db22ef32f1bd0da`. Owner `postgres`, SECURITY DEFINER,
STABLE volatility, unsafe parallel flag, non-leakproof flag, service-role-only
ACL and search path all match the defining Task 5 contract.

Local string construction reproduces the exact Production raw digest and CRLF
count from the canonical source. The correction is therefore classified
`PRECONDITION CHANGE`, not `PRODUCT FIX`. New forward migration
`20261110150000` normalizes only stored source representation and preserves
all routine attributes. Its preflight/postflight/focused rollback behavior and
Task 5/Task 6 regression sequence are documented in
`docs/runbooks/BACKOFFICE_AR_REVERSAL_HELPER_SOURCE_NORMALIZATION_ROLLOUT_2026-11-10.md`.

## Proven local state

- Migration state: `INSTALLED_CONSISTENT` for `20261105120000`, `20261106100000`, and `20261110100000` according to `private.kgs_schema_migrations`.
- Active Finance queue: zero.
- Replacement Invoice `INV-20261110-0000000023` is `POSTED`, has one `OPEN` schedule for Rp30.000, and has a registered Invoice open item.
- Its Rp15.000 Credit Note allocation has a matching append-only `ALLOCATION_REVERSAL` row.
- `private.ar5_item_allocated(...)` returns effective Invoice allocation zero after the reversal.
- `private.ar4_backoffice_invoice_allocated_credit(...)` incorrectly returns Rp30.000 because it sums the original Rp15.000 and reversal Rp15.000 as positive values.
- The active AR Aging consumer therefore omits the replacement Invoice even though the open-item reader correctly reports Rp30.000 residual.

## Active call chain

1. Backoffice Finance UI `CustomerReceiptView.tsx` requests `/api/finance/customer-receipts/reports`.
2. `backoffice/src/app/api/finance/customer-receipts/reports/route.ts` calls `public.get_finance_ar_aging`.
3. `public.get_finance_ar_aging` calls `private.ar4_backoffice_invoice_allocated_credit` for Backoffice Invoice credit.
4. The Task 4 helper joins Invoice debit items to Credit Note items and sums allocation amounts, but does not apply the reversal sign introduced by Task 5.
5. `open_items` filters the Invoice because its incorrectly calculated outstanding becomes zero.

## Impact map

### Direct impact

- Correct only `private.ar4_backoffice_invoice_allocated_credit` so original allocations add and reversal rows subtract.
- No table, column, UI payload, permission, accounting entry, or historical row rewrite is required.

### Downstream consumers inventoried from active local definitions

- `public.get_finance_ar_aging` — report visibility and totals.
- `public.get_finance_customer_receipts` — Invoice candidate/outstanding workspace.
- `public.get_backoffice_sales_invoice_payment_context_before_unified_rev` — Invoice payment context.
- `private.backoffice_invoice_receivable_before_receipts` — canonical receivable before receipts.
- `private.reconcile_backoffice_invoice_receivable_schedule` — schedule status/credited amount reconciliation.
- `private.plan_backoffice_invoice_revision_journals` — revision Journal planning.

### Explicitly preserved

- Original Credit Note allocation still reduces AR.
- Reversal remains append-only; no allocation row is deleted or updated.
- Receipt allocations, Customer Balance usage, Cash/Bank refunds, and price corrections are not counted by this Credit-Note-only helper.
- Posted Journals and Finance Events are immutable.
- Credit Note refund of Rp5.000 remains a separate open-item consumption and balanced AR-to-Bank Journal.
- POS Retail, retained-Retail bridge, Backoffice Stock/Reservation/FIFO/HPP, SO/dispatch, and Invoice posting are unchanged.
- Same-Company/customer guards, permissions, idempotency, stale-version checks, and retry ownership remain in their existing Task 5 functions.

### Compatibility and regression risks

- Historical Task 4 allocations have `reversal_of_allocation_id IS NULL` and retain the same value.
- Task 5 reversal rows must be subtracted only when their debit and credit items match the Invoice/Credit Note pair.
- As-of reads must include allocations/reversals only up to the requested effective date, falling back to `created_at::date` for legacy rows.
- Risk: replacing the helper with unfiltered `ar5_item_allocated` would double-count Receipts or other credit types. That approach is explicitly rejected.
- Risk: correcting only AR Aging would leave payment/workspace/revision consumers contradictory. The fix must be central in the shared helper.

## Finance, stock, audit, and transaction boundaries

- Finance: read/reconciliation correction only; no new Journal/Event and no mutation of posted accounting.
- Stock/Reservation/FIFO/HPP: no call-chain intersection and must remain unchanged in behavior tests.
- Payment: Receipt allocation remains separate from explicit Credit Note allocation.
- Audit: allocation and reversal rows remain append-only and attributable to their existing operations.
- Concurrency/idempotency/retry: no mutation API changes; existing advisory locks and operation retry contracts are preserved.
- Rollback/forward-fix: already-live migration versions are immutable. Correction must use a new guarded forward migration. If the forward migration cannot be accepted, the safe rollback is another forward migration restoring the immediately captured function definition; do not delete ledger rows or edit applied migrations.

## Test matrix

| Case | Expected invariant |
| --- | --- |
| Invoice without Credit Note allocation | helper remains zero; Aging unchanged |
| Active partial/full Credit Note allocation | helper equals active allocation; Invoice outstanding reduced |
| Allocation then reversal | helper returns pre-allocation value; Invoice returns to Aging/workspace/payment context |
| Allocation as-of before reversal | allocation remains visible for that historical date |
| Allocation as-of on/after reversal | reversal is netted |
| Credit Note refund | refund consumes Credit Note residual but is not treated as Invoice allocation |
| Customer Balance usage / Receipt | excluded from this helper |
| exact retry / changed retry / stale residual | existing Task 5 behavior suite remains PASS |
| replacement Invoice | open-item residual and AR Aging outstanding agree after reversal |
| POS/retained Retail/Stock/FIFO | zero behavior change |
| same/cross Company and customer | existing denial coverage remains PASS |

## Unknowns and gate result

- Unknown affecting design: none for the local product fix.
- Production database state remains `UNKNOWN`; no production rollout may be inferred from local evidence.
- Phase A result: `AUDIT COMPLETE` for local forward-fix design. Phase B may change only the shared helper through a new guarded migration plus preflight, postflight, and rollback-only behavior proof.

## Production closure evidence

Production migration `20261110130000` is database-live. After the required
Company-date dependency and two proven test-harness corrections, the sequential
Production rollback matrix passes for Task 3 Invoice/Receipt, Task 4 native
Credit Note, Customer Receipt Credit Note outstanding, Task 5 open-credit
actions with `parityConsumerAssertions:true`, and Task 6 replacement Invoice.
Every behavior reports full rollback. Closing parity postflight reports ledger
one, exact reversal-aware runtime digest, protected helper execution, and zero
invalid Invoice items. Its zero reversal-row inventory is not used as behavioral
proof; Task 5's active parity assertion supplies that proof.

Status: `AUDIT COMPLETE` YES; `DATABASE LIVE` YES; `CUMULATIVE ROLLBACK
REGRESSION PASS` YES; `CLIENT DEPLOYED` unchanged; authenticated Production
`SMOKE PASS` NO; `UAT PASS` NO. No additional migration is authorized by this
closure; the next gate is authenticated browser smoke.

## Test harness correction log

- First local preflight execution failed before any migration with `relation public.pos_offline_submission_queue does not exist`.
- Classification: `TEST_HARNESS_FIX`; product runtime and database were not changed.
- The invalid identifier was replaced only after tracing the active finance preflights, which define the queue as `public.pos_offline_sale_submissions` with nonterminal statuses `QUEUED`, `SYNCING`, and `NEEDS_CONFIRMATION` (for example `supabase/diagnostics/backoffice_ar_credit_note_open_credit_preflight.sql:160`).
- No assertion or product invariant was removed or weakened.
- The first browser UI parity attempt also stopped before clicking because the
  harness detected the `Terapkan` button while it was still disabled during
  report loading. This was classified `TEST_HARNESS_FIX`; the wait condition
  was narrowed to an enabled button while the expected visible outstanding
  remained Rp50.000.
- A subsequent UI selector falsely failed because the `OUTSTANDING` label and
  value are siblings rather than parent/child. Its captured body already proved
  `INVOICE TERBUKA 2`, `OUTSTANDING Rp50.000`, Invoice `...0021` Rp20.000, and
  replacement Invoice `...0023` Rp30.000. The selector was corrected to assert
  those visible values without changing product state.
