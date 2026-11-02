# POS Delivery Modal Layering Fix Impact Audit — 2026-11-02

## Classification and expected outcome

- Task classification: `PRODUCT_BEHAVIOR_CHANGE`.
- Fix classification: `PRODUCT FIX`.
- Expected outcome: from the Katalog checkout, a cashier can enable
  `Perlu dikirim`, open `Atur pengiriman`, fill the Delivery fields, and click
  `Simpan pengiriman` with a normal pointer action. The parent checkout remains
  open and the subsequent `Simpan Draft` retains the exact Delivery payload.
- Source of truth: user instruction on 2026-11-02 plus the existing Delivery
  Draft browser assertion in `qa-e2e/tests/retail-pwa.mocked.spec.ts`.

## Files and active implementation read

- `pwa/src/App.tsx:4497-4518` — Katalog checkout overlay and dialog.
- `pwa/src/App.tsx:5150-5194` — checkout sticky action bar and enclosing tree.
- `pwa/src/App.tsx:5797-5910` — Delivery overlay, fields, and save button.
- `pwa/src/App.css:1803-1849` — checkout overlay is fixed at `z-index: 70`.
- `pwa/src/App.css:3272-3300` — Delivery dialog sizing/scrolling.
- `pwa/src/App.css:3516-3524` — checkout `.pos-action-bar` is sticky at local
  `z-index: 5`.
- `pwa/src/App.css:3698-3707` — shared action-dialog presentation.
- `pwa/src/App.css:5193-5204` and `5457-5459` — mobile checkout and action-bar
  behavior.
- `qa-e2e/tests/retail-pwa.mocked.spec.ts:873-903` — normal pointer Delivery
  Draft path and exact RPC payload assertion.
- `docs/audits/POS_COMPREHENSIVE_E2E_TEST_HARNESS_IMPACT_2026-11-01.md` — frozen
  26/27 baseline and failure evidence.

## Proven active execution path

1. `Atur pembayaran` sets `checkoutOpen=true`.
2. Katalog layout renders `.pos-checkout-overlay.is-open`; active CSS places
   that full-screen overlay at `z-index: 70`.
3. `Perlu dikirim` selects `fulfillmentMode='DELIVERY'` and opens
   `deliveryDetailsOpen`.
4. Delivery renders later in the same `App` root as a fixed
   `.pos-action-dialog-overlay` with Tailwind `z-[60]`.
5. Because 60 is below the parent checkout overlay's 70, the checkout remains
   the effective pointer target. Playwright repeatedly reports
   `.pos-action-bar` intercepting the normal click on `Simpan pengiriman`.
6. The click never reaches `setDeliveryDetailsOpen(false)`; consequently the
   test cannot proceed to the canonical `save_pos_sale_draft_with_ketul`
   payload assertion.

The browser accessibility snapshot independently shows both dialogs and the
filled Delivery values while the screenshot/hit test keeps the checkout above.
The live local Chrome window also confirms the active Katalog checkout uses the
same source branch. No Production mutation was performed during the audit.

## Identifier sources and state

- `.pos-checkout-overlay`: defined in `pwa/src/App.css`; active class assembled
  in `pwa/src/App.tsx`.
- `.pos-action-dialog-overlay`: defined in `pwa/src/App.css`; Delivery consumer
  in `pwa/src/App.tsx`.
- `.pos-action-bar`: defined and rendered in the same files.
- `save_pos_sale_draft_with_ketul`: existing test payload assertion sourced from
  the active client wrapper; it is not changed by this fix.
- Migration/database state: `NOT APPLICABLE`. This is a client stacking fix;
  no table, RPC, migration, data, Event, or Journal changes.

## Impact map

### Direct impact

- Raise only the Delivery overlay above the Katalog checkout overlay.
- Normal mouse/touch hit-testing reaches the Delivery dialog and save button.

### Downstream impact

- Delivery state still lives in the existing React state.
- Closing Delivery reveals the still-open checkout, which then saves/posts by
  the unchanged Draft/checkout handlers.
- Delivery fee, recipient, address, schedule, notes, and Invoice display mode
  payloads remain unchanged.

### Explicitly unaffected

- Pickup and Delivery business classification;
- Cash, non-cash, split, Tempo, Ketul, and internal settlement;
- Stock, reservation, FIFO/HPP, payment verification, cashier session;
- Finance Event/queue/Journal and audit;
- Backoffice/ODR fulfillment and dispatch;
- same-Company/cross-Company authority;
- exact retry, stale version, concurrency, rollback, and historical data.

### Regression risks

- Delivery overlay could cover the checkout incorrectly after close.
  Mitigation: behavioral test must prove close, parent checkout continuity, and
  exact Draft payload.
- Raising all shared dialogs could reorder unrelated modals.
  Mitigation: change only the Delivery consumer, not the shared class.
- Desktop fix could regress mobile full-screen checkout.
  Mitigation: preserve fixed inset/scroll rules and inspect desktop plus narrow
  viewport behavior.
- Existing dirty-worktree UI changes could be overwritten.
  Mitigation: one-token class edit only; no broad refactor.

## Before/after and test matrix

| Case | Before | Required after | Evidence |
|---|---|---|---|
| Katalog Delivery modal | visible in AX, below checkout hit-test | normal save click works | focused Playwright |
| Delivery Draft payload | unreachable after modal step | exact recipient/address/Rp5.000 payload | RPC assertion |
| Direct final post | not part of Draft case | remains absent | negative RPC assertion |
| Pickup | unaffected | existing direct Retail Pickup still PASS | full POS suite |
| Cash/QRIS/split/Tempo/Ketul | unaffected | all existing cases PASS | full POS suite |
| Session open/close and operational modals | unaffected | all existing cases PASS | full POS suite |
| Runtime POS/Backoffice separation | unaffected | 8/8 contract cases PASS | runtime suite |
| Desktop live/local UI | broken layering reproduced by automated browser | Delivery save clickable | visual smoke |
| Narrow viewport | same z-order applies | overlay stays above checkout and scrollable | responsive inspection/test |

Database-only dimensions (Stock/FIFO/Finance, cross-Company, retry,
concurrency) are not behaviorally exercised because the patch cannot reach or
change those layers. Their existing server authority is preserved.

## Implementation boundary

- Planned product file: `pwa/src/App.tsx` only.
- Planned test change: none required for the primary regression; the existing
  failing assertion is retained unchanged.
- Documentation/handoff will record the result.
- No migration, backfill, deployment, Production write, or data rollback.

## Rollback / forward fix

- Rollback: restore the Delivery overlay's prior z-index class.
- If a new modal ordering issue appears, stop and re-audit the complete overlay
  stack; do not lower the checkout or raise the shared class opportunistically.

## Unknowns

- Unknown affecting design: `NONE`.
- Authenticated Production smoke and UAT remain unproven until deployment and
  user validation; they do not affect the local layering design.

## First focused rerun — frozen precondition failure

- The unchanged Delivery browser test still reported the original pointer
  interception after the source edit.
- Evidence proves it did not execute the edited bundle:
  - `pwa/src/App.tsx` timestamp: 2026-11-02 05:50;
  - `pwa/dist/index.html` and its JS bundle timestamp: 2026-11-01 22:52;
  - `qa-e2e/playwright.config.ts` runs `vite preview` with
    `reuseExistingServer: true` and does not build the PWA;
  - port 5197 was already reused from the earlier comprehensive run.
- Classification: `PRECONDITION CHANGE`. Product code and the failing
  assertion remain frozen. The valid next step is to build current source, then
  rerun the exact normal-click test against that rebuilt bundle.

## Rebuilt focused rerun — harness sequencing failure

- The rebuilt bundle contains `z-[75]`; after `Perlu dikirim` is checked, the
  Delivery overlay now correctly sits above checkout and intercepts background
  pointer actions.
- The test then timed out trying to click checkout's `Atur pengiriman` button
  behind that already-open Delivery overlay.
- Active source `selectFulfillmentMode('DELIVERY')` at
  `pwa/src/App.tsx:1665-1681` explicitly calls
  `setDeliveryDetailsOpen(true)`. The additional click in the test is therefore
  redundant and not the user flow implemented by the product.
- Classification: `TEST HARNESS FIX`. The correction removes only that
  redundant background click. It retains the normal click on
  `Simpan pengiriman`, exact Delivery Draft payload assertions, and the
  no-final-post assertion.

## Final implementation and evidence

- Product correction: only the Delivery dialog consumer in
  `pwa/src/App.tsx` was raised from `z-[60]` to `z-[75]`. The shared dialog
  class, checkout overlay, sticky footer, and every server contract remain
  unchanged.
- Harness correction: removed only the redundant click on the background
  `Atur pengiriman` control after `Perlu dikirim` had already opened the
  Delivery dialog. The normal click on `Simpan pengiriman`, exact Delivery
  payload assertions, and negative final-post assertion remain intact.
- Focused Delivery Draft test: `1/1 PASS`.
- Full command: `npm.cmd --prefix qa-e2e run test:pos`.
- Full POS result: `27/27 PASS` in 41.3 seconds, including all eight runtime
  contract cases.
- `npm.cmd --prefix pwa run lint`: PASS.
- `npm.cmd --prefix pwa run build`: PASS; only the pre-existing Vite chunk-size
  warning remains.
- Local laptop visual inspection on `http://127.0.0.1:5190`: PASS. The Delivery
  dialog visibly renders above checkout and `Simpan pengiriman` is reachable;
  the dialog was closed without saving or posting a transaction.

## Final status

- `AUDIT COMPLETE`: YES.
- `LOCAL READY`: YES for this client layering fix and the mocked POS gate.
- `DATABASE LIVE`: not applicable; no database or migration change.
- `CLIENT DEPLOYED`: NO.
- `SMOKE PASS`: NO authenticated database/Production smoke was run.
- `UAT PASS`: NO.

The 27/27 result proves the local mocked browser and source-contract scope
listed in the matrix above. It does not prove the separately listed real
database, Finance, concurrency, or Production gaps.

