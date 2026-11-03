# POS Retail Session Net Return Summary Impact Audit (2026-11-02)

## Classification and requested outcome

- Task classification: `SCHEMA_OR_MIGRATION_CHANGE` plus a scoped
  `PRODUCT_BEHAVIOR_CHANGE` in the POS Session Summary read model.
- Requested outcome: when a Retail POS cashier closes a session, the visible
  session figures must agree with the real effects executed in that session:
  cash/non-cash payment totals are net of Posted refunds and Product Out is net
  of physical returns received during the session.
- Explicit boundary from the user: this behavior applies only to the Retail
  process. Backoffice Sales Order/Return approval and presentation must not
  change.

## Source of truth and proven active path

### Current Session Summary display

1. `pwa/src/SessionSummaryModal.tsx` calls
   `loadCashierSessionSummary(cashierSession.id)`.
2. `pwa/src/lib/pos.ts::loadCashierSessionSummary()` reads:
   - `sales_headers` by `session_id`;
   - `sales_details` for those Sales;
   - non-reversal `sales_payments` for those Sales;
   - `public.get_pos_expense_workspace(uuid)` for the selected session.
3. `SessionSummaryModal.tsx::totals` adds only Sale payment rows. It does not
   read or subtract Return refunds.
4. `SessionSummaryModal.tsx::allSessionProducts` adds only Sale line quantity.
   It does not read or subtract physical Return lines.

The displayed `Cash diterima`, non-cash total, per-method breakdown, total
payment, and `Produk keluar` are therefore gross figures. This is the proven
display defect.

### Actual close-session Cash calculation

`private.calculate_cashier_session_expected_cash(uuid,uuid)`, most recently
defined by
`supabase/migrations/20260805130000_g4_phase52_customer_balance_sale_credit.sql`,
already subtracts `sales_return_refunds.amount` when:

- the parent `sales_return_documents.status='POSTED'`;
- `sales_return_documents.executing_session_id` is the session being closed;
- `sales_return_refunds.payment_method_type_snapshot='CASH'`.

The canonical close path calls this calculator. The close-session mutation is
already net of Cash refund and must not be rewritten by this task.

### Actual Stock/FIFO effect

The canonical Return Post core writes the physical Return effect. The latest
negative-source restoration forward fix is
`20261102120000_pos_sales_return_negative_stock_restoration.sql`, for which the
user reported rollback behavior and postflight PASS. This task must not change
Stock, Movement, FIFO/HPP, negative-stock reconciliation, or Return posting.

## Identifier evidence

| Identifier | Defining/active evidence |
| --- | --- |
| `sales_return_documents.executing_session_id` | `20260803010000_g4_phase26_sales_return_foundation.sql` |
| `sales_return_documents.status`, `source_sales_id`, `company_id` | same foundation migration |
| `sales_return_lines.quantity_uom`, Product/UOM snapshots, `return_condition` | same foundation migration |
| `sales_return_refunds.amount`, payment method/type/route snapshots | same foundation migration |
| `SALEABLE`, `DAMAGED`, `NO_PHYSICAL_RETURN` | `sales_return_line_condition_check` in the foundation migration |
| `sales_headers.sales_origin`, `sales_process_mode` | active Sale runtime and direct Retail migration `20261102100000` |
| Retail process mode `RETAIL_CONFIRM_INVOICE` | `company_sales_process_settings.active_mode`, consumed by `20261102100000` |
| Backoffice mode `BACKOFFICE_DELIVERED_QTY_INVOICE` | current process inventory/preflight evidence for `20261102100000` |
| direct authenticated SELECT revocation on Return tables | `20260813050000_acp_phase5h_sales_return_permission_enforcement.sql` |

The proposed new identifier
`public.get_pos_cashier_session_return_adjustments(uuid)` is an additive,
narrow read RPC introduced by this design. It does not exist in the audited
runtime and must remain absent until the preflight proves `NOT_INSTALLED`.

## Retail-only server boundary

The new read RPC may include a Return only when all of these are true:

1. the selected Cashier Session belongs to the active Company and current
   authenticated cashier;
2. the Return is `POSTED` and its `executing_session_id` equals that session;
3. its source Sale has `sales_origin='POS'`;
4. its source Sale has `sales_process_mode='RETAIL_CONFIRM_INVOICE'`;
5. the active Company setting is `RETAIL_CONFIRM_INVOICE`.

This deliberately excludes:

- `BACKOFFICE_DELIVERED_QTY_INVOICE` Companies; the RPC returns
  `applicable=false` with empty adjustments so their existing presentation is
  not broken or reinterpreted;
- Backoffice-origin Sales and Returns;
- retained/cutover Backoffice Return paths;
- Draft/Canceled Return documents;
- Return activity executed by another session or Company.

The PWA cannot directly query Return tables because authenticated SELECT was
revoked. A SECURITY DEFINER RPC with the ownership checks above is required;
client-side filtering is not an authorization boundary.

## Planned result contract

The read RPC returns only summary adjustments for the selected Retail session:

- `refunds`: Return/document identity, payment method id/name/type/route, and
  amount;
- `lines`: Return/document identity, Product id/name/SKU, UOM, quantity, and
  Return condition.

The client derives:

- Cash net = counted Retail Sale Cash payments minus Retail Posted Cash refunds;
- non-cash net = counted Retail Sale non-cash payments minus matching Posted
  non-cash refunds;
- method net = Sale payment amount minus refund amount per method snapshot;
- total payment net = Cash net plus non-cash net;
- Product Out net = sold quantity in this session minus `SALEABLE`/`DAMAGED`
  quantity physically received by this session;
- `NO_PHYSICAL_RETURN` affects payment totals but does not reduce Product Out.

Attribution follows the executing session. Consequently, a Return of an older
Sale executed today can produce a negative Product Out quantity for today; that
is the truthful net stock movement of the selected session, not an error.

## Impact map

### Direct impact

- New additive Retail-only read RPC and supporting index only if the preflight
  proves the index is absent and needed.
- `pwa/src/lib/pos.ts`: load/map the RPC result into the Session Summary type.
- `pwa/src/SessionSummaryModal.tsx`: subtract refund/physical Return rows and
  label the figures as net values.
- Mocked POS E2E: cover Cash, non-cash, physical, and no-physical Return cases.

### Downstream impact

- The visible summary becomes consistent with the existing close-session Cash
  calculator and actual Return Stock effects.
- No mutation path is added. The new RPC is read-only and returns snapshots.
- Closing Cash, drawer movement, payment verification, Finance Event/Journal,
  Return Post, Stock, Reservation, FIFO/HPP, audit, and receipts remain owned by
  their current canonical runtimes.

### Explicitly preserved

- all Backoffice Sales Order and Sales Return flows, approval layers, statuses,
  read models, and Finance behavior;
- Retail Return posting and refund method behavior;
- Expense totals and selected-session Expense ownership;
- split payment, Tempo, internal balance, Cash auto-verification, and non-cash
  verification;
- open/closed session close mutation and expected-Cash calculator;
- multi-Company isolation and historical rows;
- exact retry, stale version, idempotency, concurrency, and audit of every
  existing mutation.

## Concurrency, retry, and compatibility

- The proposed RPC is `STABLE` and read-only. It creates no retry key and no
  write race.
- Each RPC call observes one PostgreSQL statement snapshot. Client aggregation
  is based on the returned immutable Posted Return snapshots.
- The close mutation remains server-authoritative and recalculates expected
  Cash independently. The UI summary is informative and cannot override close
  amounts.
- Existing Return rows require no backfill; the read model uses existing
  `executing_session_id` and snapshots.
- If database state is partial/inconsistent or the active close calculator no
  longer contains the proven Return subtraction, implementation must stop.

## Regression matrix

| Scenario | Required result |
| --- | --- |
| Retail session without Return | Values remain identical to current Sale/Expense summary. |
| Retail Cash refund | Cash and method total decrease; close expected Cash agrees. |
| Retail QRIS/Transfer refund | Non-cash and method total decrease; Cash is unchanged. |
| Split refund | Each method is reduced by its own Posted refund snapshot. |
| `SALEABLE` physical Return | Product Out quantity decreases. |
| `DAMAGED` physical Return | Product Out quantity decreases because stock physically re-enters a warehouse. |
| `NO_PHYSICAL_RETURN` | Payment decreases; Product Out does not. |
| Old Sale returned in current session | Current session shows refund and inbound Product adjustment. |
| Draft/Canceled Return | Excluded from every net figure. |
| Return executed in another session | Excluded from selected session. |
| Backoffice process Company | New RPC fails closed/returns no Retail adjustment; Backoffice UI/runtime unchanged. |
| Backoffice-origin source Sale | Excluded even if a row references a Cashier Session. |
| Same/cross Company | Own session succeeds; cross-Company session is denied. |
| OPEN/CLOSED own session | Historical/active own-session reads remain deterministic; mutation remains unchanged. |
| exact repeated load | Same snapshot produces the same result and no write. |
| close during/after refresh | server close calculator remains authoritative. |

## Migration state and mandatory gate

- Repository state for proposed version `20261102150000`: local candidate
  created; object not deployed. The earlier `130000` number was retired before
  rollout because `140000` became database-live while this task was paused.
- Production state: `UNKNOWN` until
  `supabase/diagnostics/pos_retail_session_net_return_summary_preflight.sql`
  proves the dependency ledger, object absence, active close calculator, table
  privileges, and Retail/Backoffice inventory.
- No Phase B source/schema edit is authorized before that output is classified.

## Rollback / forward-fix

- Migration rollout will be additive. Rollback before client deployment is to
  drop only the new RPC/index if no client depends on it.
- After the migration is live it becomes immutable. Any defect requires a new
  forward migration; do not edit/rerun the live version.
- The client can be rolled back independently to the prior gross display; doing
  so does not change the already-correct close-session Cash calculation.

## Current status

- `AUDIT COMPLETE`: YES for repository call-chain scope.
- `LOCAL READY`: YES. The guarded migration/read RPC, rollback-only behavior,
  postflight, PWA mapping, net aggregation, and browser/runtime contracts are
  present. PWA build, lint, focused browser coverage, and the complete mocked
  POS suite pass.
- `DATABASE LIVE`: YES for migration `20261102150000`. The user confirmed the
  rollback-only behavior succeeded and supplied a complete postflight with all
  mandatory rows PASS: ledger, stable SECURITY DEFINER RPC, Retail/POS guards,
  RPC privilege, and continued authenticated direct-table denial.
- `CLIENT DEPLOYED`: NO.
- `SMOKE PASS`: NO.
- `UAT PASS`: NO.

The first focused browser run failed only because the test selector for
`Cash net sesi` also matched `Non-cash net sesi`; the rendered values already
matched the invariant. This was classified as `TEST_HARNESS_FIX`, the selector
was anchored without changing expected values, and the rerun passed.
