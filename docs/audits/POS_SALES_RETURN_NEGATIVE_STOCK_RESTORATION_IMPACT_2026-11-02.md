# POS Sales Return Negative-Stock Restoration Impact Audit (2026-11-02)

## Classification and outcome

- Classification: `SCHEMA_OR_MIGRATION_CHANGE`.
- Requested outcome: a legitimate physical Sales Return must not fail merely
  because its source Sale consumed authorized negative stock instead of a
  positive FIFO batch.
- Exact reproduced source: KGS invoice `INV-20261101-0000000951`, five units of
  `Daging Burger Sapi`, positive FIFO `0`, negative shortage `5`, replenished
  `0`, error `SOURCE_SALE_FIFO_RESTORATION_EXHAUSTED`.
- Phase A only. No Product/schema/runtime mutation is authorized until the
  exact Production preflight closes the remaining object-state and population
  questions.

## Source of truth and active execution path

1. `public.get_pos_returnable_sales(...)`, latest wrapper in migration
   `20260829110000`, exposes sold/dispatched quantity minus Posted Return
   quantity; it does not require positive FIFO capacity.
2. `public.submit_pos_sales_return_with_delivery_fee(...)`, installed by
   `20261102100000`, directly finalizes only POS + `RETAIL_CONFIRM_INVOICE` and
   preserves Backoffice approval.
3. It calls `private.acp5h_post_sales_return_core(...)`. The currently installed
   core has the optional-Transfer correction from `20261102110000` and loops
   only `sale_fifo_allocations` / `sales_return_fifo_restorations` for physical
   Return cost and Stock restoration.
4. Authorized negative Sale lineage is stored in
   `negative_stock_sale_allocations`; replenishment/cost settlement is stored in
   `negative_stock_replenishment_allocations`.
5. Every inserted `product_batches` row invokes
   `private.reconcile_negative_stock_replenishment()` through trigger
   `g4_reconcile_negative_stock_replenishment`. Its latest repository
   definition is in `20260919143000` and consumes new batch quantity against
   open POS negative Sale, Backoffice negative Sale, then Purchase Return
   shortages.
6. `private.post_sales_return_financial_event_core(...)` reads
   `sales_return_lines.fifo_cost_restored`. It reverses COGS and debits Inventory
   by that cost; it does not require the cost source to be a positive FIFO row.

## Identifier sources

| Identifier | Defining/latest source |
| --- | --- |
| `sale_stock_requirements` | `20260729070000_g4_phase4_atomic_sale_runtime.sql` |
| `sale_fifo_allocations` | same migration |
| `negative_stock_sale_allocations` | `20260805190000_g4_phase58_negative_stock_policy_foundation.sql` |
| `negative_stock_replenishment_allocations` | same migration |
| `private.reconcile_negative_stock_replenishment()` | latest replacement in `20260919143000_backoffice_purchase_return_negative_stock_runtime.sql` |
| `sales_return_fifo_restorations` | `20260803010000_g4_phase26_sales_return_foundation.sql` |
| `product_batches.sales_return_line_id` | same migration |
| `product_batches_source_lineage_check` | latest shape in `20260911140000_backoffice_sales_negative_dispatch_runtime.sql` |
| `private.acp5h_post_sales_return_core(...)` | foundation `20260803010000`, permission rename `20260813050000`, ODR patch `20260829110000`, optional metadata patch `20261102110000` |

## Impact map

### Direct impact

- Add explicit negative-source lineage to Return-created Product batches.
- Add immutable Return negative-restoration rows so quantity/cost cannot be
  restored twice and the source negative allocation remains auditable.
- Patch the batch replenishment trigger so a Return batch targets its exact
  source negative allocation instead of silently consuming the oldest unrelated
  shortage.
- Patch the canonical Return posting core after positive FIFO restoration to
  restore the negative portion deterministically.

### Cost and Stock rules

- Positive FIFO remains first and unchanged.
- For an unreplenished source-negative slice, Return uses the source provisional
  unit cost. The returned batch closes that exact negative shortage with zero
  variance, its remaining batch quantity becomes zero, and Product Stock moves
  toward zero once through the existing Return movement.
- For a previously replenished slice, Return uses the exact historical actual
  replenishment unit cost and creates on-hand returned stock without changing
  the already-settled source shortage.
- Every negative-source Return batch carries its exact source allocation.
  The patched replenishment trigger therefore never offers it to the generic
  oldest-shortage queue. An outstanding source consumes only its own Return
  batch; an already-replenished source leaves the Return batch available as On
  Hand at its exact historical actual cost. The 149 observed collision rows do
  not cause cross-Sale allocation or an unposted variance.
- `fifo_cost_restored` remains the existing Finance input but becomes the total
  restored source cost from positive FIFO plus negative-source slices.

### Preserved consumers and boundaries

- POS Retail direct finalization and Backoffice Draft/approval routing.
- Cash/Transfer refund, Tempo/Customer Receipt, Delivery fee and tax behavior.
- Sale Return quantity, Warehouse-condition, tenant, actor, version and exact
  retry guards.
- Existing positive FIFO Return behavior and immutable historical rows.
- Generic Goods Receipt, Backoffice negative Dispatch, Purchase Return shortage
  replenishment, their triggers and Finance cost-variance sources.
- Other Companies receive the same server capability only when their exact Sale
  lineage requires it; no Company-specific hardcoding.

## Concurrency, idempotency, retry, rollback

- Lock Return document/detail, source requirement, exact negative allocation,
  and cost-source replenishment rows before calculating availability.
- Unique Return-negative restoration identity prevents double consumption.
- Existing Return operation ID and final document replay remain authoritative.
- All batch, replenishment, Stock movement, Event and Journal effects remain in
  the same transaction; an error rolls everything back.
- Installed migrations are immutable. Correction requires a new guarded
  forward migration and a forward-fix rather than editing live files.

## Required regression matrix

| Scenario | Expected result |
| --- | --- |
| Exact invoice 0951, five unreplenished negative units | Posts Return; source shortage closes 5; returned batch consumed against shortage; one Stock movement; HPP reversed at provisional cost. |
| Partial negative Return | Only returned quantity closes; remaining shortage stays open. |
| Positive FIFO-only Return | Existing restoration and cost unchanged. |
| Mixed positive FIFO + negative source | Positive allocation restored first, negative remainder restored once. |
| Previously replenished negative source, no collision | Actual replenishment cost restored; returned batch stays available. |
| Previously replenished source with another open shortage | Exact-source tag bypasses the unrelated queue; returned batch remains On Hand and no cross-Sale variance is created. |
| Exact retry / changed retry / stale version | Existing replay/conflict behavior preserved. |
| Cash / Transfer / split refund | Settlement behavior unchanged. |
| Retail / Backoffice | Retail direct; Backoffice approval preserved. |
| Same/cross Company | Tenant-scoped; cross-Company denied. |
| Finance | Return Event/Journal balanced using combined restored cost. |
| Rollback | Zero persisted Return, Stock, batch, replenishment, Event or Journal effect. |

## Open evidence and gate

- User-provided Production preflight: all mandatory gates PASS.
- Target state: `NOT_INSTALLED`; all seven dependencies are installed.
- Exact active Return-core MD5: `9a4ec8f10eacec926435e99deb1fca26`.
- Exact replenishment-trigger MD5: `ef37126de5f098b97223d9877e460cd1`.
- Active lineage constraint is the expected four-branch pre-correction shape;
  neither core nor trigger is negative-Return aware.
- Exact invoice is unchanged: shortage `5`, replenished `0`, positive FIFO `0`,
  visible remaining `5`. `collision=true`, but the exact Return batch is fully
  consumed by its explicitly targeted five-unit source shortage; no residual
  batch reaches another allocation.
- Production inventory: `759` candidates across four Companies; `158`
  unreplenished, `601` fully replenished, `0` partially replenished, `0` mixed
  positive/negative, and `149` collision rows.
- Finance queue and Offline submissions are idle.
- Phase A is complete for the bounded forward fix. Phase B uses explicit batch
  lineage to prevent any residual quantity from entering the unrelated
  replenishment queue and patches only the proven core/trigger digests.

## Phase B package and rollback/forward-fix note

- Candidate migration:
  `supabase/migrations/20261102120000_pos_sales_return_negative_stock_restoration.sql`.
- It adds explicit Product Batch lineage, an immutable Return-negative
  restoration ledger, an exact-source helper, and guarded patches to the two
  proven runtime digests.
- Postflight:
  `supabase/diagnostics/pos_sales_return_negative_stock_restoration_postflight.sql`.
- Authenticated rollback-only behavior:
  `supabase/tests/pos_sales_return_negative_stock_restoration_behavior.sql`.
- Rollback before commit is automatic because the migration is transactional.
  After installation, do not delete the ledger or edit/replay this migration;
  any defect requires a new forward migration after another impact audit.
- `DAMAGED` Return into a different Warehouse remains fail-closed for a
  negative-only source (`NEGATIVE_SOURCE_RETURN_DESTINATION_MISMATCH`). This
  correction intentionally covers the proven saleable Return failure without
  inventing cross-Warehouse shortage accounting.
- User-confirmed target state: migration `20261102120000` installed;
  SELECT-only postflight PASS; authenticated rollback-only behavior PASS.
  The installed migration is immutable and must not be rerun or edited.
- Remaining evidence: one real authenticated POS Return smoke and UAT are
  pending. Database behavior PASS must not be represented as real transaction
  or UAT PASS.
- PostgreSQL 18.4 accepted the complete top-level statement/delimiter grammar
  of the migration, postflight, and behavior files. The empty parser-only
  database then stopped at the expected missing-schema preconditions; this is
  not evidence of full runtime compilation or behavior.
