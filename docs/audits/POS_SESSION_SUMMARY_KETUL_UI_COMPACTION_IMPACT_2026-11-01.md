# POS Session Summary and Ketul UI Compaction Impact Audit (2026-11-01)

## Classification and expected business outcome

- Task classification: `PRODUCT_BEHAVIOR_CHANGE` (presentation and interaction
  layout only).
- Requested outcome:
  1. the Session Summary header and totals consume materially less vertical
     space so the transaction/product list is the dominant viewport area;
  2. the Ketul entry point and Ketul line editor use the established light POS
     visual language, remain readable, and adapt cleanly to tablet/mobile.
- No deployment, production mutation, database change, or business-rule change
  is authorized by this slice.

## Evidence and active execution paths

### Session Summary

1. `pwa/src/App.tsx` renders `SessionSummaryModal` for the active
   `CashierSession` and passes the existing payment-method catalog, document
   opener, and Return opener.
2. `pwa/src/SessionSummaryModal.tsx::load()` calls the existing read-only
   `loadCashierSessionSummary(cashierSession.id)` implementation.
3. The component derives Cash, non-Cash, total, and per-method display totals
   from the returned session transactions; it does not write them.
4. `pwa/src/App.css` currently uses
   `.pos-session-summary-totals { grid-template-columns: repeat(4, ...) }` for
   five cards. Direct browser inspection at `127.0.0.1:5190` proved the fifth
   total card wraps alone to a second row. The header, cards, method strip,
   tabs, and search consume roughly the upper half of the modal before the
   first transaction row.
5. `qa-e2e/tests/retail-pwa.mocked.spec.ts` already covers customer-first
   Session Summary content, payment breakdown, Expense totals, row expansion,
   and Return shortcut.

### Ketul

1. `pwa/src/App.tsx` gates the entry point with the proven
   `catalog.ketulEnabled && !isBackofficeCutoverDraft` condition and opens
   `KetulIntakeModal` without writing data.
2. `pwa/src/KetulIntakeModal.tsx` owns only draft rows and retains the existing
   validation: product/qty/unit price required, identical products merge only
   at identical price, and the Ketul total may not exceed the Sale total.
3. Saving the editor returns the same `KetulIntakeLineInput[]` to `App.tsx`.
   Existing checkout code later supplies those lines to the already-installed
   `save_pos_sale_draft_with_ketul` and `post_pos_sale_with_ketul` paths.
4. Direct browser inspection proved the current checkout entry card mixes dark
   emerald utility colors with the light checkout surface, producing very low
   text/button contrast. The modal uses a single dense four-column row with a
   nearly icon-only delete action and weak total/action hierarchy.
5. `qa-e2e/tests/retail-pwa.mocked.spec.ts` already proves Ketul readiness
   fail-closed, hidden settlement method, exact line payload, post-tax offset,
   and final posting path.

All identifiers above come from the cited active source and tests. No table,
column, enum, RPC, or migration identifier is introduced.

## Runtime and migration state

- Relevant schema/migration state: `INSTALLED_CONSISTENT` for the existing Ketul
  runtime based on the repository handoff and the user-provided postflight;
  this UI slice neither changes nor reruns it.
- Session Summary uses the existing live read model; this slice changes no
  database object.
- Local browser state was inspected read-only. The Session Summary was closed,
  checkout and Ketul dialogs were opened, and no form was saved or posted.

## Impact map

### Direct impact

- `pwa/src/SessionSummaryModal.tsx`: add stable presentation hooks only if
  needed for layout/test evidence; values and actions remain identical.
- `pwa/src/App.css`: compact the Session Summary header/cards/tooling, keep all
  five totals on one desktop row, make the list consume remaining height, and
  use horizontal/compact responsive totals instead of a tall mobile stack.
- `pwa/src/App.tsx`: replace the Ketul launch card's incompatible utility-color
  styling with named POS classes; retain all enable/disable conditions and
  callbacks.
- `pwa/src/KetulIntakeModal.tsx`: restructure only the visual hierarchy and
  responsive markup; retain draft-state and commit validation verbatim.
- `qa-e2e/tests/retail-pwa.mocked.spec.ts`: add geometry/visibility evidence for
  the compact Session Summary and responsive Ketul editor without weakening
  existing business assertions.

### Downstream impact

- None to Stock, reservation, FIFO/HPP, payment, cashier-session accounting,
  Finance Event/queue/Journal, receipt snapshots, audit rows, or Return.
- Ketul input values still enter the same draft/post payload only after the
  cashier explicitly applies them and completes the existing checkout.

### Explicitly preserved

- POS versus Backoffice/ODR separation;
- Company/feature/readiness gates and cross-Company isolation;
- all payment methods, split payment, Tempo, and non-cash verification;
- opening Cash, session Expense, payment totals, transaction/product filters,
  row expansion, canonical document action, and Return shortcut;
- Ketul product, positive qty/price, duplicate-price, maximum-offset, online,
  non-Tempo, Cart, and readiness guards;
- exact retry, stale version, idempotency, concurrency, and historical data;
- existing schema, migrations, installed database runtime, and other Companies.

## Regression risks

- Compacting cards can truncate large IDR values or the Expense explanation.
  Controls: minmax columns, responsive overflow, and browser geometry checks.
- Giving the list flex ownership can collapse it when the modal is short.
  Controls: `min-height: 0` on the flex child plus an explicit usable minimum.
- A visual Ketul rewrite could accidentally alter commit behavior or hide the
  error state. Controls: preserve `commit()` unchanged and rerun exact payload,
  limit, hidden-payment, and readiness tests.
- Nested overlays can produce scroll/close regressions. Controls: keep existing
  overlay z-index/callbacks, test both desktop and mobile viewport containment,
  and do not submit a real transaction during visual smoke.

## Test matrix

| Scenario | Required result |
| --- | --- |
| Desktop Session Summary | Five totals share one row; transaction list remains visible and owns remaining height. |
| Narrow/mobile Session Summary | Totals stay compact and reachable without creating a multi-row wall; tabs/search/list remain usable. |
| Large IDR and Expense detail | Values and supporting text remain readable without overlap. |
| Transaction/product tabs | Existing filters and list behavior remain unchanged. |
| Ketul entry disabled | Existing online/Tempo/Cart/product/readiness guards still win. |
| Ketul desktop | Entry card has readable contrast; row fields, delete, total, and actions have clear hierarchy. |
| Ketul mobile/multiple rows | No horizontal overflow; rows stack; footer actions remain reachable. |
| Valid Ketul | Exact line payload and hidden post-tax offset remain unchanged. |
| Invalid/over-limit Ketul | Existing validation remains visible; no payload is committed. |
| POS/Backoffice, Stock/FIFO, Finance | No code path or database effect changes. |

## Rollback / forward-fix

No migration or data rollback exists. Rollback is a narrow revert of the named
PWA markup/CSS/test changes. Any unexpected lint/build/Playwright or browser
smoke failure freezes further patching and returns this task to read-only audit;
business assertions may not be weakened to obtain a PASS.

## Status before implementation

- `AUDIT COMPLETE`: yes.
- `LOCAL READY`: no; implementation and tests not yet run.
- `DATABASE LIVE`: existing runtime only; no database change in this slice.
- `CLIENT DEPLOYED`: no.
- `SMOKE PASS`: no.
- `UAT PASS`: no.

## First verification failure and re-audit

The first focused Playwright run stopped with `2 failed` and revoked any local
readiness claim:

1. **Ketul label mismatch — PRODUCT FIX.** The visual rewrite shortened the
   applied state from the established `1 jenis Ketul` to `1 jenis`. Screenshot
   evidence proved the state and amount were rendered, but the noun was lost.
   The product copy will retain `jenis Ketul`; the existing assertion is not
   weakened.
2. **Session list height assertion — TEST HARNESS FIX.** The mock contains one
   transaction, so a flex modal with `max-height` correctly settles at its
   explicit 140px list minimum instead of manufacturing empty height. The
   screenshot proved all five cards are on one row and the first transaction is
   visible. The invariant needed by the user is the vertical space consumed
   *before* the list and list overflow ownership, not unused height for a
   one-row fixture. The corrected assertion will keep the 140px minimum and add
   a maximum header-to-list distance; it does not remove the five-card geometry
   assertion or any business assertion.

No Stock, payment, Finance, session, Ketul payload, or database failure was
observed because the Ketul test stopped before its existing payload assertions.
Those assertions remain unchanged and must run on the retry.

## Authenticated local visual finding

After the focused retry and full mocked Retail suite passed, direct inspection
of the local authenticated Session Summary with 21 transactions exposed a
responsive regression at the browser's 894px logical width: the horizontally
scrollable total cards were compressed vertically until only their lower edge
was visible. The direct cause is normal flex shrinking on non-list children of
`.pos-session-summary-dialog` when the transaction list has a large content
basis. This is a `PRODUCT FIX`, not a test-only issue.

The correction is limited to making the header, total strip, payment-method
strip, tabs, and search `flex: 0 0 auto`; `.pos-session-summary-list` remains the
only `flex: 1 1 auto` overflow owner. No value, action, or data path changes.

## Final local evidence and status

- PWA `oxlint`: PASS.
- TypeScript + Vite production build + PWA generation: PASS.
- Complete mocked Retail PWA file: `7/7 PASS`.
- Session geometry at `1920x900`: five cards share `y=224.5`; each is
  `224x89.5`; the list starts 335px below the dialog top and retains its 140px
  minimum for the one-row fixture.
- Ketul desktop/mobile browser checks: dialog remains within viewport, mobile
  has no horizontal overflow, and the exact line payload, `Rp10.000` offset,
  hidden settlement option, posting call, and readiness fail-closed assertions
  all PASS.
- Authenticated local browser inspection with the real 21-transaction KGS
  session: cards remain full-height at 894px logical width, horizontal card
  overflow is contained, and four transaction rows plus part of the fifth are
  visible without scrolling the page. No transaction was saved or posted.
- `git diff --check`: PASS apart from existing line-ending warnings.

Status:

- `AUDIT COMPLETE`: yes.
- `LOCAL VERIFICATION PASS`: yes.
- `DATABASE LIVE`: not applicable to this UI-only slice; existing runtime was
  not changed.
- `CLIENT DEPLOYED`: no.
- `SMOKE PASS`: authenticated local read-only visual smoke only; no Sale was
  posted during this slice.
- `UAT PASS`: no; user visual acceptance remains pending.
