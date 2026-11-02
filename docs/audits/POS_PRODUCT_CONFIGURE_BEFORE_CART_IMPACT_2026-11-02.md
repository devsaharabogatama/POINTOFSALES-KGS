# POS Product Configure Before Cart Impact Audit - 2026-11-02

## Classification and expected business outcome

- Task classification: `PRODUCT_BEHAVIOR_CHANGE` limited to client-side Cart
  composition before Draft/checkout.
- Source of truth: explicit user decision on 2026-11-02.
- Expected flow: selecting a Product from Catalog or Compact opens the existing
  Product editor with an uncommitted line; only `Masukkan ke keranjang` commits
  that line. After commit, the existing Cart `Edit` action remains available.
- Cancel, overlay click, close, or Escape while adding must leave Cart, Draft,
  totals, price preview inputs, Stock, and Finance unchanged.
- Production mutation/deployment: not authorized.

## Proven active execution path and identifier sources

1. `pwa/src/App.tsx:147-153` defines the client-only `CartItem` shape.
2. `pwa/src/App.tsx:524-535` owns `cart`, quantity input state, and
   `editingCartProductUomId`.
3. `pwa/src/App.tsx:1217-1264` previews canonical prices for every Catalog
   Product and uses Cart quantity when present. A new uncommitted line can use
   the already-loaded Product preview without a database mutation.
4. `pwa/src/App.tsx:1816-1848` currently commits immediately through
   `addToCart(product)` and merges an existing Product-UOM line.
5. `pwa/src/App.tsx:3950-3958` is the Compact picker caller.
6. `pwa/src/App.tsx:4093-4098` is the Catalog card caller.
7. `pwa/src/App.tsx:4243-4257` and `4458-4467` open the same editor for existing
   Catalog and Compact Cart lines.
8. `pwa/src/App.tsx:5258-5449` renders the existing editor. Its quantity,
   override, and discount controls currently mutate Cart directly; its close
   actions merely close the editor.
9. `pwa/src/App.tsx:1548-1593` owns Escape behavior, while
   `pwa/src/App.tsx:3133-3180` resets Sale/Cart UI state.
10. `qa-e2e/tests/retail-pwa.mocked.spec.ts` contains seven direct Catalog
    selection consumers plus the complete mocked POS flow.

All identifiers above are sourced from current repository code. Database and
migration state are `NOT_APPLICABLE`: Product selection is local React state and
does not call a mutation until Draft/save/post later in checkout.

## Impact map

### Direct impact

- Introduce one temporary `CartItem` draft for a newly selected Product.
- Replace both immediate-add callers with a shared Product-configuration opener.
- Reuse the existing editor presentation for pending and existing lines.
- Route quantity, price override, and discount edits to the temporary item while
  adding, and to the existing Cart mutation path while editing.
- Pending footer uses `Batal` and `Masukkan ke keranjang`; existing lines retain
  `Hapus produk` and `Selesai`.
- Preserve one Cart line per Product-UOM. Selecting a Product already in Cart
  opens its existing editor instead of creating an ambiguous duplicate line.

### Downstream impact and explicitly preserved behavior

- Cart totals, Draft payload, checkout, payment, Ketul, Tempo, Delivery, offline
  calculation, and posting continue to read only committed `cart` rows.
- Price source remains the existing server preview, with Product fallback only
  where it was already used.
- Price-override visibility and Terminal authority are unchanged.
- Product-UOM precision, line discount shape, and existing remove/edit behavior
  are unchanged after commit.
- No effect on Company/role/feature boundaries, cashier session, Stock,
  Reservation, FIFO/HPP, Payment, Finance Event/queue/Journal, audit, retry,
  idempotency, concurrency, historical data, Backoffice, or other Companies.

## Regression risks and controls

| Risk | Control |
| --- | --- |
| Cancel accidentally adds an item | Pending item is separate from `cart` until explicit confirm. |
| Pending control edits mutate an existing row | One branching editor update helper targets pending state or the proven existing update path. |
| Existing Cart edit semantics regress | Existing Edit continues to address `editingCartProductUomId`; its footer and delete path are preserved. |
| Compact and Catalog diverge | Both selection callers use the same opener. |
| Existing tests bypass the new confirmation | Test helper must click Product, assert Cart is unchanged, then confirm through the visible dialog. |
| Escape/reset leaves a ghost pending item | Escape, close, overlay, reset, and workspace switch clear pending state. |

## Required before/after test matrix

| Scenario | Required assertion |
| --- | --- |
| New Catalog Product | Click opens editor; Cart remains unchanged until confirmation. |
| Cancel new Product | Close/Batal leaves Cart and total unchanged. |
| Confirm new Product | Configured quantity/discount enters exactly one Cart line. |
| Edit committed Product | Existing Edit opens same controls and preserves current behavior. |
| Existing Product selected again | Existing line editor opens; no duplicate Product-UOM row appears. |
| Compact picker | Picker closes, editor opens, confirm adds the Product. |
| Escape/reset | Pending item is discarded. |
| Narrow viewport | Editor remains usable. |
| Full mocked POS suite | All Draft, checkout, Ketul, Delivery, split-payment, Tempo, Return, Expense, session and runtime contract tests remain green. |

## Rollback and unresolved conditions

- Rollback is a source revert of the pending editor state/routing and associated
  browser assertions.
- Unknown affecting design: `NONE`. The user specified the confirmation boundary;
  current code proves the editor controls and both Product selection callers.

## Phase B implementation and evidence

- `pwa/src/App.tsx` now holds a newly selected Product in temporary
  `pendingCartItem` state and opens the shared Cart editor before committing it.
- `Masukkan ke keranjang` is the only new-line commit boundary. `Batal`, close,
  overlay, Escape, reset, and workspace changes discard the temporary line.
- Selecting an already committed Product-UOM opens the existing edit path and
  does not create a duplicate line. Catalog and Compact route through the same
  opener.
- `qa-e2e/tests/retail-pwa.mocked.spec.ts` covers pre-commit configuration,
  cancel, Escape, confirmation, post-commit edit, duplicate prevention, and
  Compact routing. Existing direct Product-selection fixtures were updated to
  cross the new explicit confirmation boundary; business assertions were not
  weakened.

Evidence:

- `npm.cmd run lint` in `pwa`: PASS.
- `npm.cmd run build` in `pwa`: PASS; existing Vite chunk-size warning only.
- Focused configure-before-Cart browser test: `1 passed`.
- Full `npm.cmd --prefix qa-e2e run test:pos`: `28 passed`.
- Authenticated local laptop check at `http://127.0.0.1:5190`: clicking
  `Bidayah ROTI Burger isi 10` displayed `Tambah produk`, quantity, price and
  discount controls plus `Masukkan ke keranjang`, while the Cart remained zero;
  `Batal` returned to the Catalog with the Cart still zero. No Draft, Sale,
  payment, Stock, Finance, Company, or session mutation was made.

Status boundary:

- `AUDIT COMPLETE`: YES.
- `LOCAL READY`: YES for this client behavior.
- `DATABASE LIVE`: N/A; no database change.
- `CLIENT DEPLOYED`: NO.
- `SMOKE PASS`: NO for authenticated end-to-end posting; the authenticated
  laptop evidence is limited to the non-mutating open/cancel path.
- `UAT PASS`: NO.

