# POS Comprehensive E2E Test Harness Impact Audit — 2026-11-01

## Classification and boundary

- Task classification: `TEST_HARNESS_ONLY`.
- Product behavior, PWA UI, schema, migrations, Production database, and deployed
  clients are explicitly outside this change.
- The safe automated layer uses an isolated Supabase HTTP mock. It may verify
  browser behavior, active RPC names, payload shape, UI state transitions, and
  fail-closed behavior, but it must not be reported as authenticated database
  smoke or Production UAT.

## Source of truth and files read

- `AGENTS.md` and `docs/AI_AGENT_CONTINUATION_PLAYBOOK.md` — execution and
  evidence gates.
- `docs/POS_V1_MVP_REQUIREMENT_INDEX.md` and the active sections of
  `docs/POS_V1_IMPLEMENTATION_GATES.md` — cross-module invariants.
- `docs/POS_DEVELOPMENT_NOTES.md`, `docs/POS_EXPENSE_CASH_FLOW_SPEC.md`, and
  `docs/KETUL_WORKFLOW_NOTES.md` — POS, Expense, and Ketul flow decisions.
- `pwa/src/App.tsx` — active Cashier shell, checkout, Draft/Order, session close,
  and modal wiring.
- `pwa/src/lib/pos.ts` — exact table reads, RPC identifiers, and payload mapping.
- `pwa/src/{SalesReturn,ExpenseRequest,StockRequest,GoodsReceipt,PurchaseReturn,
  StockOpname,CashDeposit,SessionSummary,KetulIntake}Modal.tsx` — active form
  lifecycle and visible validation.
- `qa-e2e/tests/retail-pwa.mocked.spec.ts` and
  `qa-e2e/tests/runtime-contract.spec.ts` — current fixtures and assertions.

## Baseline evidence

- PWA production build: PASS on 2026-11-01; existing chunk-size warning only.
- Existing scoped POS Playwright baseline: 15/15 PASS:
  - seven browser tests in `retail-pwa.mocked.spec.ts`;
  - eight static runtime-contract tests.
- Baseline browser coverage proves direct Pickup checkout, Catalog geometry,
  Ketul ready/fail-closed entry, refund-method field boundary, direct Expense,
  and Session Summary. It does **not** prove all operational workspaces.

## Active call chains and defining identifiers

| Feature | UI entry / implementation | Active runtime identifier |
|---|---|---|
| Cashier session | `App.tsx` | `open_cashier_session`, `close_cashier_session` |
| Direct Retail sale | `App.tsx` → `postSale` | `post_pos_sale_with_pricelist`; Ketul wrapper `post_pos_sale_with_ketul` |
| Draft / Order | `App.tsx`, `SalesOrderPanel.tsx` | `save_pos_sale_draft*`, `list_pos_sale_drafts`, `get_pos_sales_orders`, confirm/cancel/revision RPCs |
| Return | `SalesReturnModal.tsx` | `get_pos_returnable_sales`, `save_sales_return_draft_with_delivery_fee` |
| Expense | `ExpenseRequestModal.tsx` | `get_pos_expense_workspace`, `post_pos_expense` |
| Stock Request | `StockRequestModal.tsx` | `get_pos_stock_request_workspace`, `save_stock_request`, `submit_stock_request` |
| Goods Receipt | `GoodsReceiptModal.tsx` | `get_pos_goods_receipt_supplier_orders`, `save_goods_receipt`, `post_goods_receipt` |
| Supplier Return | `PurchaseReturnModal.tsx` | `get_pos_purchase_return_workspace`, `save_purchase_return_draft`, `cancel_purchase_return_draft` |
| Stock Opname | `StockOpnameModal.tsx` | `get_pos_stock_opname_workspace`, `save/start/record/complete/cancel_stock_opname*` |
| Cash Deposit | `CashDepositModal.tsx` | `list_cash_deposit_eligible_sessions`, `save_cash_deposit_draft`, `submit_cash_deposit` |
| Session Summary | `SessionSummaryModal.tsx` | session-scoped Sale/Payment/Expense reads |
| Offline | `App.tsx`, `lib/offline*.ts` | offline catalog/allowance/queue RPC and IndexedDB boundary |

All identifiers above were read from active product source. No table, column,
RPC, enum, or response shape may be invented in the new fixture.

## Impact map

### Direct impact

- New/extended Playwright fixture responses and browser assertions.
- A dedicated POS-only command that builds the PWA, runs comprehensive mocked
  browser tests plus runtime contracts, and leaves an HTML report.

### Downstream impact

- CI/local QA duration increases.
- A product regression can now fail a focused POS gate before deployment.
- No runtime bundle imports the test files.

### Regression risks

- A mock can drift from the live RPC contract. Mitigation: runtime-contract
  assertions and exact payload checks sourced from `lib/pos.ts`.
- A green mock can be mistaken for database smoke. Mitigation: separate status
  names and explicit report wording.
- Weak assertions can pass after a button click without proving mutation.
  Mitigation: every mutative browser case must assert the exact RPC call and
  material payload fields, plus the resulting UI state.

### Compatibility and invariants preserved

- POS and Backoffice flows remain separate.
- Draft/Hold/Pending do not claim final stock or Finance effects.
- Cash, non-cash, split, Tempo, and hidden Ketul settlement remain distinct.
- Return/Receipt/Opname tests assert their source linkage and do not reinterpret
  them as generic stock adjustments.
- Same-company fixture scope is explicit; cross-company authority remains a
  server/database test and is not simulated as proof here.
- Idempotency/stale-version/concurrency are server contracts. Browser tests may
  assert key reuse and error presentation, but full transactional proof remains
  in SQL behavior/authenticated smoke.

## Comprehensive browser matrix

| Area | Positive case | Negative/boundary case | Required evidence |
|---|---|---|---|
| Login/bootstrap | Cashier reaches active OPEN session | public login remains fail-closed | visible shell + no unexpected request |
| Catalog/cart | search/add/edit and fixed total | empty cart blocks checkout | UI state |
| Customer | select/quick create | Walk-In restrictions retained | RPC/payload + selector state |
| Checkout | Cash, non-cash, split | payment imbalance/proof/Tempo boundary | save/post payload |
| Draft/Order | save, reopen/cancel, order list | stale/locked/final errors remain visible | exact RPC and preserved cart |
| Ketul | ready intake/offset | not-ready and hidden payment method | exact Ketul payload |
| Return | Cash and Transfer field boundary | amount/required transfer metadata | return payload |
| Expense | direct paid POS expense | legacy second disbursement hidden | `post_pos_expense` payload |
| Stock Request | save then submit | empty/invalid line blocked | both RPC calls |
| Goods Receipt | draft then post | rejected quantity no stock claim | save/post payload |
| Supplier Return | draft for approval | required reason / no direct stock post | save payload only |
| Opname | create/start/count/complete | blind count and unresolved confirmation | lifecycle RPC sequence |
| Setor Kas | closed-session allocation | confirmation/amount validation | save/submit payload |
| Session Summary/Close | session-only totals/close | closed session cannot continue | summary + close RPC |
| Offline | status/queue boundary | unsupported final checkout remains blocked | no online final-post claim |

## Status semantics

- `MOCKED E2E PASS`: browser and exact client contract passed against the
  isolated fixture.
- `RUNTIME CONTRACT PASS`: source wiring still references canonical runtime.
- `AUTHENTICATED SMOKE PASS`: reserved for a separately authorized staging/test
  database run with real side effects and downstream verification.
- `UAT PASS`: reserved for user acceptance.

## Rollback

This is test-only. Rollback removes the new suite/runner and restores any
fixture-only edits. No database forward-fix or data rollback is applicable.

## First comprehensive run — frozen failure and classification

- Run result: 11/13 browser cases passed; Goods Receipt and Supplier Return
  timed out after their source-selection action.
- Failure screenshots prove both Product UIs correctly transitioned to their
  detail forms and rendered the expected inputs.
- Root cause: each Playwright locator filtered the dialog by its list-screen
  heading. The heading intentionally changes after source selection, so the
  previously defined locator no longer matched the same dialog.
- Classification: `TEST HARNESS FIX`.
- Product source, fixture response, business assertion, RPC payload assertion,
  and expected outcome remain unchanged. The correction may only replace the
  unstable heading-filtered locator with the stable unique `role=dialog`
  boundary.
- Focused rerun after that correction: Goods Receipt PASS; Supplier Return
  reached the correct detail form but its product checkbox selector timed out.
  The screenshot and component source prove the checkbox is a sibling of the
  product text inside the same wrapping label, not a child of the text node's
  immediate parent. Classification remains `TEST HARNESS FIX`; correction is
  limited to selecting the unique checkbox in that detail dialog.
- Sales expansion focused run: Quick Customer PASS. Split payment failed only
  because label text associated both the Cash invoice-share and tendered inputs;
  source defines stable `payment-amount-*` ids for the invoice-share fields, so
  this is `TEST HARNESS FIX`. Tempo correctly produced `dueDate=null` because
  the fixture Customer has no credit term and the test never filled the UI's
  required manual due-date field. This is `PRECONDITION CHANGE`, not an excuse
  to remove the date assertion: the corrected valid-flow test must enter a
  manual due date and assert that exact value reaches the Draft payload.
- Focused correction rerun: Tempo PASS. Split reached final post but the test
  expected QRIS `tenderedAmount=0`. Active `postSaleWithNegativeReason` proves
  payment methods without overpayment support normalize tendered amount to the
  invoice-share amount. The observed `10000/10000` payload is the defined
  contract; correcting the expected tendered amount is `TEST HARNESS FIX` and
  retains the two-leg and exact-total assertions.
- First dedicated-runner execution built the PWA successfully but ran zero
  tests because port 5197 was already occupied by a prior local Playwright
  preview. Classification: `TEST HARNESS FIX`. The POS config may reuse that
  local preview after the runner has rebuilt `pwa/dist`; this makes repeated
  local runs deterministic without terminating unrelated user processes.
- Final three-path focused run: opening a Cashier Session PASS and saving a
  Cash Sales Return Draft PASS. Delivery Draft reached the active delivery
  modal, but Playwright strict mode rejected `getByLabel('Ongkir')` because it
  matched both the currency textbox labelled `Ongkir` and the separate
  checkbox labelled `Tampilkan rincian ongkir di Invoice`. `pwa/src/App.tsx`
  lines 5865-5871 and 5884-5898 prove those are distinct controls and the
  failure happened before mutation. Classification: `TEST HARNESS FIX`.
  Correction is limited to the exact textbox role/name; Delivery payload and
  no-direct-post assertions remain unchanged.

## Final local execution state

- Command: `npm.cmd --prefix qa-e2e run test:pos`.
- Current PWA production build: PASS; existing Vite chunk-size warning only.
- Original baseline: `26 PASS / 1 FAIL / 27 total` because the Delivery dialog
  was below the checkout hit-test layer.
- After the audited product fix in
  `docs/audits/POS_DELIVERY_MODAL_LAYERING_FIX_IMPACT_2026-11-02.md`, the same
  full runner is `27 PASS / 0 FAIL / 27 total`.
- All eight runtime-contract tests PASS.
- Delivery now uses fixed `z-[75]` only for that consumer; normal pointer save,
  exact Delivery Draft payload, and no-final-post assertions PASS.
- Status: test harness and audited client fix `LOCAL READY`; database live is
  not applicable to the client fix; deployment, authenticated smoke, and UAT
  were not run.

