# KGFF POS Terminal Price Override Diagnosis — 2026-11-02

## Classification and outcome

- Classification: `READ_ONLY_AUDIT` for a reported tenant-specific POS behavior.
- Expected outcome: explain why KGS exposes editable unit price while KGFF does
  not, without changing Product pricing, POS behavior, database configuration,
  or another Company.
- Mutation performed: none.

## Proven active contract

1. `20260825120000_pos_terminal_price_override.sql` defines
   `pos_terminals.allow_price_override BOOLEAN NOT NULL DEFAULT FALSE`.
2. The active PWA maps this exact column to
   `Terminal.allowPriceOverride` in `pwa/src/lib/pos.ts`.
3. `pwa/src/App.tsx` exposes and enables `Harga jual` only while online and the
   active Terminal has `allowPriceOverride=true` (or while displaying an older
   Draft that already contains an override).
4. The server repricer independently requires the same active Terminal flag and
   otherwise raises `POS_TERMINAL_PRICE_OVERRIDE_DISABLED`.
5. The supported configuration writer is
   `save_pos_terminal_ui_settings(...)`, exposed through the Backoffice
   Terminal UI settings API and component. Direct authenticated column update
   is revoked.

## KGFF configuration origin

`20261008100600_kgff_retail_location_foundation_v3.sql` created KGFF `POS-1`
without specifying `allow_price_override`. The database default therefore made
the Terminal `FALSE`. Its migration postcondition checks identity/status but
does not require price override parity with KGS.

## Runtime evidence

- Laptop UI inspection on the active online KGS POS showed an editable
  `Harga jual / PACK` field in the Product editor.
- Laptop UI inspection on the active online KGFF POS showed the same Product
  editor without a price field.
- This pair matches the only active UI branch controlling that field: the
  Terminal flag. It is not controlled by Product, discount basis, Company sales
  process mode, or role in the Product editor.
- Migration `20261102160000_pos_retail_per_unit_product_discount.sql`, its
  postflight, and its behavior test contain no reference to `pos_terminals`,
  `allow_price_override`, or `allowPriceOverride`. The newly installed discount
  migration did not create this difference.

## Impact map for a possible configuration correction

### Direct

- Only KGFF `POS-1` Terminal UI policy would change from OFF to ON through the
  canonical versioned settings writer.
- Online Product editor would expose editable unit price.

### Downstream

- A cashier-entered override is revalidated server-side and snapshotted into
  canonical/final Sale-line pricing and audit columns.
- Invoice, payment, tax, Session totals, and Finance consume the final validated
  Sale amount.
- Quantity, Stock, Reservation, FIFO, and HPP formulas are not changed.

### Preserved

- KGS and every other Company/Terminal.
- Offline override denial.
- Pricelist remains canonical when no override is entered.
- Existing Draft/Posted history and Backoffice Sales flow.
- Actor, Company, Store, Terminal, open-session, version, and audit guards.

## State and next safe step

- Product defect from migration `20261102160000`: not found.
- KGFF terminal configuration: UI evidence proves effective override OFF; an
  exact read-only database row is still useful before mutation to record ID,
  version, and current flag.
- No fix was applied during this diagnosis.
- If the user authorizes parity, use the existing Backoffice Terminal settings
  flow to enable price override for KGFF `POS-1`, then reload POS and smoke:
  edit one price, save/resume Draft, post, and verify canonical/final price and
  audit while KGS and Offline remain unchanged.
