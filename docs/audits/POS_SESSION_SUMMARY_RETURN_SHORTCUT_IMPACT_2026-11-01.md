# POS Session Summary Return Shortcut Impact Audit (2026-11-01)

## Classification and expected outcome

- Task classification: `PRODUCT_BEHAVIOR_CHANGE`.
- Requested outcome: every transaction/customer row in the POS Session Summary
  transaction list exposes a Return button at the right side. Selecting it must
  open the existing Sales Return workflow already focused on that exact Sale.
- This slice is a navigation/prefill change only. It does not create a second
  Return implementation and does not authorize deployment or production writes.

## Source of truth and current state

- Task-2 point 5 is defined in
  `docs/audits/POS_SALES_RETURN_REFUND_METHOD_UI_IMPACT_2026-10-31.md`:
  the canonical POS flow creates a Return Draft and Backoffice posts it; the
  final Posted Return note records the actual refund method.
- The active Return database contract is classified `INSTALLED_CONSISTENT` by
  the existing audit and rollout evidence. This slice requires no migration.
- Before this slice, `SessionSummaryModal` only expanded a transaction and
  offered `Buka dokumen`. The local client now contains the audited shortcut;
  it has not been deployed.

## Active execution path and identifier evidence

1. `pwa/src/lib/pos.ts::loadCashierSessionSummary()` reads `sales_headers`
   scoped by `session_id` and maps the proven `sales_headers.id` to
   `CashierSessionSummaryTransaction.salesId`. It also exposes the invoice and
   draft identifiers as `documentNo` and `orderNo`.
2. `pwa/src/SessionSummaryModal.tsx` renders those transactions. It currently
   receives only `openTransaction`; the shortcut will add an explicit
   `openReturn(transaction)` callback without changing the existing row-expand
   and document-open behavior.
3. `pwa/src/App.tsx` owns `sessionSummaryOpen` and `salesReturnOpen`, and renders
   the lazy `SalesReturnModal` only when an open Session, active Company, and
   terminal `SALES_RETURN` feature are present.
4. `pwa/src/SalesReturnModal.tsx` calls
   `pwa/src/lib/pos.ts::loadSalesReturnWorkspace()`.
5. `loadSalesReturnWorkspace()` calls the exact active RPC
   `public.get_pos_returnable_sales(text,integer)`, most recently defined by
   `supabase/migrations/20260829110000_odr_phase6d_sales_return_consumer_compatibility.sql`.
6. The RPC is Company-scoped, requires an authenticated cashier with an OPEN
   Session, limits results to the cashier's Store, accepts invoice search, and
   only returns a Sale with a posted/dispatched returnable quantity remaining.
7. Saving still uses
   `public.save_sales_return_draft_with_delivery_fee(...)`; approval/posting,
   Stock/FIFO, Cash, Finance Event, Journal, and audit remain unchanged.

All identifiers used by this change are sourced from the files above. No new
table, column, enum, RPC, or migration identifier is introduced.

## Impact map

### Direct impact

- `pwa/src/SessionSummaryModal.tsx`
  - render one Return action on each transaction row at the right;
  - keep row expansion independently clickable;
  - disable the action while another shortcut is opening;
  - expose clear online/feature eligibility through the parent callback.
- `pwa/src/App.tsx`
  - retain the selected Session Summary Sale identity;
  - close the summary and open the existing Return modal;
  - clear the selection whenever Return closes or completes.
- `pwa/src/SalesReturnModal.tsx`
  - accept optional initial Sale/invoice identity;
  - search by the exact invoice and automatically select the matching
    returnable Sale;
  - show a fail-closed message if the Sale is no longer returnable.
- `pwa/src/App.css`
  - position the action on the right without nesting interactive buttons and
    retain usable mobile layout.
- `qa-e2e/tests/retail-pwa.mocked.spec.ts`
  - verify shortcut visibility, exact-Sale selection, and preservation of the
    existing Session Summary and refund-method behavior.

### Downstream impact

- The shortcut causes one filtered `get_pos_returnable_sales` read when opened.
- No Return Draft is written until the cashier explicitly submits the existing
  Return form.
- Existing Backoffice approval, refund posting, printable Return note,
  Stock/FIFO restoration, Cash Session effect, Finance Event/Journal, and audit
  remain the only mutation path.

### Explicitly preserved

- the header Return button and its browse/search workflow;
- Session Summary row expansion and `Buka dokumen`;
- POS versus Backoffice/ODR boundaries;
- Cash versus Transfer refund contract and Posted-only Return note;
- same-Company/Store/OPEN Session and feature gates;
- cumulative returned quantity, optimistic version, idempotency, concurrency,
  stale-version handling, and immutable historical Return data;
- other Companies and existing production data.

### Regression risks and controls

- Nested buttons would produce invalid interaction and accidental row toggles;
  the row header and Return action must be sibling controls.
- A Session Summary row is not proof it remains returnable. The RPC remains the
  authority and the UI must not infer eligibility from display status alone.
- A broad unfiltered 50-row Return query may omit an older selected Sale. The
  shortcut must query using the exact invoice identifier before matching
  `salesId`.
- Clicking Return while offline or while the feature is unavailable must fail
  closed and must not silently open a partial workflow.

## Regression matrix

| Scenario | Required result |
| --- | --- |
| Posted/dispatched Sale with remaining quantity | Return button opens the exact Sale directly. |
| Sale fully returned | Existing Return modal shows a clear no-longer-returnable error; no write. |
| Draft/Canceled/non-returnable row | Server eligibility wins; no Return Draft is fabricated. |
| Header Return button | Existing browse/search behavior remains unchanged. |
| Row expand and Buka dokumen | Both remain functional and independent from Return. |
| Offline | Shortcut is denied with an online requirement; no write. |
| Feature unavailable | Shortcut is not enabled; no hidden bypass. |
| Cash/Transfer | Existing conditional fields and refund snapshots remain unchanged. |
| Stock/FIFO/Finance/Cashier Session | No effect until canonical Return posting. |
| Same/cross Company and Store | Existing server scope remains authoritative. |
| Exact retry/stale version | Existing save/post RPC behavior remains unchanged. |
| Mobile layout | Customer, identifiers, status, total, and Return action remain readable. |

## Rollback / forward-fix

No migration, backfill, or production data mutation is required. Rollback is a
narrow source revert of the optional initial-selection props, Session Summary
action/wiring, CSS, and tests. Any unexpected product or smoke failure freezes
patching and returns the task to read-only audit; assertions must not be
weakened.

## Verification plan and status

- focused lint for all changed PWA files;
- PWA production build;
- mocked Playwright: Session Summary Return opens the exact Sale;
- regression: header Return browse flow and Cash/Transfer conditional fields;
- authenticated local smoke before any deployment;
- deployed authenticated smoke and UAT only after explicit deployment approval.

Current status:

- `AUDIT COMPLETE`: yes.
- `LOCAL READY`: yes. Focused PWA lint and production build PASS. Mocked
  Playwright proves the header Return Cash/Transfer regression and the Session
  Summary shortcut-to-exact-Sale path: `2/2 PASS`.
- `DATABASE LIVE`: existing canonical Return runtime only; no DB change planned.
- `CLIENT DEPLOYED`: no.
- `SMOKE PASS`: mocked local browser coverage only; authenticated smoke not run.
- `UAT PASS`: no.
