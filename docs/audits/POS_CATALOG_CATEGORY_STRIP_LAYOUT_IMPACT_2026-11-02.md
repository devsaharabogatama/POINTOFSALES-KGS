# POS Catalog Category Strip Layout Impact Audit - 2026-11-02

## Classification and expected outcome

- Task classification: `PRODUCT_BEHAVIOR_CHANGE` limited to responsive client
  layout.
- Expected outcome: in Catalog mode, the category controls render immediately
  below the product search row, remain fully visible/clickable, and use a
  compact height so the Product grid retains most of the workspace.
- User evidence: the live local KGS Catalog screenshot shows only a thin clipped
  fragment of the category strip between search and Product cards.
- Production mutation/deployment: not authorized.

## Active execution path and identifier sources

1. `pwa/src/App.tsx:752-780` derives `categories`, active `category`, and
   `filteredProducts` from the loaded Product catalog.
2. `pwa/src/App.tsx:4046-4065` renders the Product search row and stock refresh.
3. `pwa/src/App.tsx:4066-4081` renders `.pos-category-tabs` directly after the
   search row and before `.pos-product-grid`.
4. Category button clicks call the existing `setCategory(item)` state path;
   no API, RPC, table, or mutation participates.
5. `pwa/src/App.css:980-997` supplies generic category-button styling with a
   38px minimum height. The Catalog consumer has no dedicated non-shrinking
   strip contract.
6. `pwa/src/App.css:878-892` separately styles the Compact product-picker
   category controls. That consumer must remain unchanged.
7. `pwa/src/App.css:4993-5015` makes desktop Catalog a vertically scrollable
   flex panel and leaves the Product grid in normal flow.

The runtime identifiers above are sourced from current repository code. Schema
or migration state is `NOT_APPLICABLE` because this is a client-only layout
change.

## Impact map

### Direct impact

- Add a Catalog-specific class to the existing category-strip element.
- Give that strip an explicit compact, non-shrinking horizontal layout.
- Reduce Catalog category button height/padding/font size without changing
  labels, active state, or click handlers.
- Keep horizontal scrolling available when categories do not fit.

### Downstream consumers inventoried and preserved

- Search filtering and category filtering continue using the same React state.
- Product cards and add-to-cart behavior are unchanged.
- Customer selector, item count, stock refresh, Cart, checkout and fixed footer
  are unchanged.
- Compact product picker retains its existing wrapped category controls.
- Mobile/narrow Catalog retains an accessible horizontal strip.
- POS/Backoffice routing, Pickup/Delivery, all payment methods, Tempo, Ketul,
  Return, Expense, cashier session, Stock, Reservation, FIFO/HPP, Finance,
  audit, retry, idempotency, concurrency and historical data are unaffected.

## Risks and compatibility controls

| Risk | Control |
| --- | --- |
| Product grid overlaps category buttons | Strip uses `flex: 0 0 auto`, explicit minimum height and visible vertical overflow. |
| Categories consume excessive height | Catalog-only buttons use compact height/padding/type. |
| Narrow viewport loses categories | Horizontal scrolling remains enabled; buttons do not wrap or shrink. |
| Compact picker regresses | New selectors require the Catalog-specific class and do not alter `.pos-product-picker-menu`. |
| Filter behavior changes | No state, handler, or filtered-product logic changes. |

## Before/after test matrix

| Scenario | Required evidence |
| --- | --- |
| Desktop Catalog | Strip is below search, above Product grid, and all buttons have positive visible height. |
| Narrow local viewport | Strip stays usable through horizontal scroll and does not overlap Product cards. |
| Category selection | Selecting the fixture category filters visible Product cards. |
| Search | Existing Product search remains usable above the strip. |
| Compact mode | Existing product-picker category layout remains unchanged. |
| Cart/checkout | Existing comprehensive POS suite remains green. |

## Implementation boundary

- Planned product files: `pwa/src/App.tsx`, `pwa/src/App.css`.
- Planned test file: `qa-e2e/tests/retail-pwa.mocked.spec.ts`.
- Documentation/handoff: this audit and
  `docs/ACTIVE_DEVELOPMENT_HANDOFF.md`.
- No schema, migration, database write, deployment, or Production data change.

## Rollback and unknowns

- Rollback is a source revert of the Catalog-specific class and CSS rules.
- Unknown affecting design: `NONE`. Current source and local browser reproduce
  the layout defect, and the request does not change business behavior.

## Implementation and evidence

- `pwa/src/App.tsx` adds `pos-catalog-category-tabs` only to the Catalog strip;
  its order remains Product search -> category strip -> Product grid.
- `pwa/src/App.css` gives that strip a 32px non-shrinking row and 30px compact
  buttons, while preserving horizontal overflow at narrow widths.
- `qa-e2e/tests/retail-pwa.mocked.spec.ts` now proves the strip geometry at
  desktop and narrow viewports and exercises `KETUL` -> `Semua` filtering.
- `npm.cmd run lint` in `pwa`: PASS.
- `npm.cmd run build` in `pwa`: PASS; existing chunk-size warning only.
- Focused Catalog geometry/filter Playwright test: 1/1 PASS.
- `npm.cmd --prefix qa-e2e run test:pos`: 27/27 PASS in 54.7 seconds.
- Authenticated local laptop check at `http://127.0.0.1:5190`: category buttons
  are fully visible immediately below Product search; selecting `KETUL` showed
  exactly four Ketul Products, then `Semua` restored the 74-item catalog.
- The laptop check did not save/post a transaction or change Company/session.

## Status

- `AUDIT COMPLETE`: YES.
- `LOCAL READY`: YES for the Catalog layout and isolated/mocked POS regression.
- `DATABASE LIVE`: not applicable; no database change.
- `CLIENT DEPLOYED`: NO.
- `SMOKE PASS`: NO full authenticated transactional smoke; the local visual and
  filter check passed without a data mutation.
- `UAT PASS`: NO; awaiting user acceptance.
