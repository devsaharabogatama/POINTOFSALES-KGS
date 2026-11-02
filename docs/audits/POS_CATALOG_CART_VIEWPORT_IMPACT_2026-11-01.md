# POS Catalog Cart Viewport — Point 7 Impact Audit (2026-11-01)

## Classification and expected outcome

- Task classification: `PRODUCT_BEHAVIOR_CHANGE` (responsive POS layout only).
- User acceptance target: in desktop **Catalog** mode, the right-hand Cart panel
  uses the available viewport height. `Total akhir` and `Atur pembayaran` remain
  together at the bottom of that panel, while the item list receives the
  remaining height and scrolls internally so more purchased items are visible.
- This is not a request to merely reduce footer padding, move the footer outside
  the Cart, or change Compact mode.
- Production mutation/deployment: not authorized and not part of this task.

## Active execution path and identifier sources

The active UI path is proven from the current source:

1. `pwa/src/App.tsx` renders `pos-workspace` with either
   `is-catalog-layout` or `is-compact-layout` from `workspaceLayout`.
2. In Catalog mode, `pos-order-column` contains `pos-cart-panel`.
3. `pos-cart-panel` contains, in order, `pos-order-head`, the scrollable
   `pos-cart-list`, and `pos-cart-total-footer`.
4. The footer reads the existing display values `paymentDue` or
   `fallbackSubtotal`; its button only opens the existing checkout dialog.
5. `pwa/src/App.css` defines the desktop layout in `@media (min-width: 760px)`.
   The active Catalog rules give `pos-order-column` only a `max-height`, while
   `pos-cart-list` is separately capped at `224px`.

No table, RPC, migration, enum, Finance identifier, or production database
state participates in this layout change. Migration/database state is therefore
`NOT_APPLICABLE`; no SQL is planned.

## Proven root cause

- `pwa/src/App.css` currently declares
  `.pos-workspace.is-catalog-layout .pos-cart-list { max-height: 224px; }`.
- `.pos-workspace.is-catalog-layout .pos-order-column` has
  `max-height: calc(100dvh - 88px)` but no required height.
- A flex child can distribute remaining space only when its parent has a
  definite height. The Catalog Cart therefore shrink-wraps its header, at most
  224px of items, and its footer. The blank viewport below it is not allocated
  to the item list.
- The existing footer is already after the item list in DOM order. Reordering
  React markup is unnecessary and would create avoidable regression risk.

## Impact map

### Direct impact

- `pwa/src/App.css`
  - desktop Catalog `pos-order-column` / `pos-cart-panel` height allocation;
  - remove the Catalog-only 224px list cap and let the list consume remaining
    panel space;
  - keep internal list scrolling and keep the footer visible at panel bottom.
- `qa-e2e/tests/retail-pwa.mocked.spec.ts`
  - add a desktop geometry assertion proving the footer is below the list and
    near the bottom of the visible Cart panel;
  - prove the list height is greater than the rejected 224px cap;
  - prove `Atur pembayaran` still opens the existing dialog.

### Downstream consumers inventoried

- Catalog Cart header and Order/Draft/New Sale actions: layout only, retained.
- Cart line Edit action and item scrolling: retained; list remains the scroll
  owner.
- Checkout overlay and `Atur pembayaran`: retained; no state or event change.
- Compact mode: explicitly excluded through Catalog-scoped selectors.
- Narrow/mobile layout (`max-width: 759px`): existing single-column natural
  flow remains unchanged.
- Customer selector, product Catalog, Draft, Order, Return, Expense and Session
  Summary: no data or event-flow change.

### Transaction and domain boundaries

- Stock, Reservation, FIFO/HPP: no impact.
- Payment, split payment, Tempo, Customer balance and Finance posting: no
  impact; displayed totals and checkout handlers are unchanged.
- Cashier session lifecycle: no impact.
- Audit, permission, Company scope and feature entitlements: no impact.
- Concurrency, idempotency, retry and stale version: no impact because no
  mutation path changes.
- Existing Draft/Posted/historical data: no impact.

## Regression risks and controls

| Risk | Control |
| --- | --- |
| Footer leaves the visible panel | Browser geometry assertion against Cart panel bounds. |
| More height is allocated but items no longer scroll | Preserve `overflow-y-auto`; test list and footer as separate regions. |
| Compact layout changes | Catalog-qualified CSS only; existing checkout E2E remains in suite. |
| Mobile becomes viewport-locked | New rules remain inside desktop media query and Catalog selector. |
| Total or checkout behavior changes | Do not edit React calculations/handlers; assert total and payment button remain visible. |
| Dirty worktree is overwritten | Limit product patch to the relevant CSS block and append focused test only. |

## Before/after test matrix

| Dimension | Before | Required after |
| --- | --- | --- |
| Desktop Catalog, non-empty Cart | Item list capped at 224px; footer can stop mid-screen | Cart fills available right-column height; list grows and footer is at its bottom |
| Desktop Catalog, overflowing Cart | List scrolls within 224px | Expanded list scrolls internally; footer stays visible |
| Desktop Compact | Existing grid/footer | Unchanged |
| Mobile/narrow viewport | Natural single-column flow | Unchanged |
| Empty Cart | Empty state plus footer | Same content, footer at panel bottom |
| Checkout action | Opens payment dialog | Still opens the same dialog |
| Total source | `paymentDue` / `fallbackSubtotal` | Unchanged |
| Company/role/session | Existing authenticated scope | Unchanged |

## Rollback and evidence plan

- Rollback is a CSS/test revert only; no database or data rollback exists.
- Required local evidence before handoff:
  1. PWA lint;
  2. PWA production build;
  3. focused mocked Playwright browser test at desktop viewport;
  4. screenshot or geometry output demonstrating panel/list/footer positions;
  5. `git diff --check` for touched files.
- Authenticated user UAT remains separate. No `CLIENT DEPLOYED`, `SMOKE PASS`,
  or `UAT PASS` claim may be made from local mocked evidence.

## Unknowns affecting design

`NONE`. The user clarified the intended surface and outcome, and the active
DOM/CSS path is present in the repository. No database evidence is required for
this UI-only behavior.

## Test-harness failure and re-audit (2026-11-01)

- First focused geometry run passed.
- After adding Compact/mobile preservation checks, the full mocked suite result
  was `6 passed / 1 failed`. The failing test had already passed all point-7
  geometry assertions and failed later while trying to click the checkout
  dialog's `Tutup pembayaran` button. Playwright reported that the existing
  sticky header intercepted pointer events.
- Classification: `TEST HARNESS FIX`. Closing the checkout dialog is not a
  point-7 acceptance condition and is unnecessary for checking Compact/mobile.
  The additional preservation checks must run before checkout is opened; the
  existing checkout-open assertion remains the final step.
- No product CSS/JS patch is authorized from this failure. The pre-existing
  modal/header pointer overlap is recorded as a separate observation and is not
  silently folded into point 7.
- No assertion, threshold, or expected business result may be weakened.

## Implemented local evidence (2026-11-01)

- Product patch is limited to the desktop Catalog selectors in
  `pwa/src/App.css`: the right column receives a viewport-relative height, the
  Cart fills it, and the list consumes remaining space without the old 224px
  cap.
- Focused Playwright geometry evidence at `1920x900`:
  - Cart panel: `y=123`, `height=736`;
  - item list: `height=590.390625` (greater than the rejected `224px` cap);
  - footer: `y=787.5`, `height=71.5`;
  - footer-to-panel-bottom delta: `0px`;
  - viewport bottom gap: `41px`.
- The same test proves Compact and `390x844` narrow Catalog keep the original
  `display: contents` flow, then proves `Atur pembayaran` still opens the
  existing checkout dialog.
- Evidence commands/results:
  - `pwa: npm.cmd run lint` -> PASS;
  - `pwa: npm.cmd run build` -> PASS;
  - full `retail-pwa.mocked.spec.ts` -> `7 passed`;
  - focused point-7 rerun -> `1 passed`, with the numeric evidence above and a
    screenshot attached to `qa-e2e/playwright-report/index.html`;
  - `git diff --check` -> PASS (line-ending warnings only).
- Status boundary: audit and local automated evidence exist. The client has not
  been deployed, authenticated Production smoke has not run, and user UAT has
  not been accepted.

## User refinement — fixed footer position (2026-11-01)

### Corrected acceptance target

- In desktop Catalog mode, `Total akhir` and `Atur pembayaran` must stay at one
  stable bottom position in the visible POS workspace.
- Product Catalog and Cart items scroll inside their own content regions. Their
  scroll position must not move the footer.
- “Fixed” means fixed within the right-hand POS workspace, not a full-width
  browser overlay and not a footer that covers Cart content.

### Re-audit of the current implementation

- The first point-7 patch gives the right column a definite height and proves
  the footer ends at the Cart panel bottom.
- However, desktop Catalog still uses the document-scroll model:
  `pos-shell.is-catalog-shell` has auto height/visible overflow and
  `pos-order-column` is `position: sticky`. The complete right column can move
  between its initial document position and its sticky position while the left
  Catalog scrolls. Therefore the previous evidence does not prove the new
  “position never changes” requirement.
- Root cause classification: incomplete layout contract, not a transaction or
  data defect.

### Revised implementation boundary

- Desktop Catalog becomes a viewport-height workspace below the dynamic
  topbar: shell uses flex, main/workspace consume the remaining height, Catalog
  owns its vertical scroll, and the right column fills the same remaining
  height without document-level sticky movement.
- Cart items retain internal scrolling. The footer remains the final flex child
  and is overridden to normal/static positioning within the fixed-height Cart;
  it cannot drift or cover lines.
- Compact and narrow/mobile keep their current layouts through scoped Catalog
  desktop selectors and the existing mobile overrides.

### Additional regression evidence required

1. Capture footer geometry before scrolling.
2. Make the Catalog content overflow, scroll the Catalog container, and capture
   footer geometry again.
3. Assert footer X/Y/width/height are unchanged within one pixel.
4. Assert the Catalog container—not the browser window—owns the scroll.
5. Retain the existing list-height, panel-bottom, Compact/mobile and checkout
   assertions.

### Revised impact

- Direct: desktop Catalog CSS scroll ownership and layout sizing.
- Downstream UI: Catalog scrolling changes from document scroll to internal
  panel scroll; Cart/Edit/checkout remain unchanged.
- Domain effects: none for Company, role, session, Stock, Reservation, FIFO,
  Payment, Finance, audit, retry, idempotency, or historical data.
- Database/migration state: `NOT_APPLICABLE`.
- Unknown affecting design: `NONE`.

### Fixed-footer local evidence

- PWA lint and production build: PASS.
- Focused browser test at `1920x900`: PASS.
- Cart panel: `y=123`, `height=765`; Cart list height: `619.390625`;
  footer: `y=816.5`, `height=71.5`; viewport bottom gap: `12px`;
  footer-to-panel-bottom delta: `0px`.
- After the Catalog container was scrolled exactly `500px`, footer geometry was
  unchanged: before `x=1239.125/y=816.5/width=667.859375/height=71.5`, after
  the same exact values. Browser `window.scrollY` remained `0`.
- Full mocked Retail regression after the fixed-footer change: `7/7 PASS`.
- The Playwright HTML report contains both the initial viewport screenshot and
  the after-Catalog-scroll screenshot.
- This is local automated evidence only; client deployment, authenticated smoke
  and user UAT remain pending.
