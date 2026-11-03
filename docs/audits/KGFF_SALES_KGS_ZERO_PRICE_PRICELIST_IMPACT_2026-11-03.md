# KGFF SALES KGS Zero-Price Pricelist Impact Audit

## Classification and requested outcome

- Task classification: `SCHEMA_OR_MIGRATION_CHANGE`; configuration-only
  forward migration. Production execution remains a separate manual gate.
- Requirement: `MST-007` Customer Pricelist pricing.
- Requested outcome: create one KGFF Customer-scoped Pricelist whose active
  rules set every active, sale-allowed Product-UOM to a fixed price of `0`, then
  assign it only to Customer `SALES KGS` so the operator does not enter rules
  one by one.
- This Phase A audit and its preflight are read-only. No Product base price,
  Pricelist, Customer, Sale, Stock, FIFO, Payment, Finance Event, or Journal was
  changed.

## Source of truth and active call chain

1. `docs/POS_V1_MVP_REQUIREMENT_INDEX.md` (`MST-007`) defines Product price as
   fallback and Customer Pricelist as higher priority than Global pricing.
2. `docs/SALES_CUSTOMER_MASTERDATA_SPEC.md` requires a regular Customer to
   reference at most one active same-Company Customer Pricelist through
   `customers.default_pricelist_id`; Walk-In cannot receive one.
3. `docs/SALES_PRICELIST_NOTES.md` defines Customer Pricelist as exclusive: a
   missing rule falls back directly to Product-UOM price, not Global tiers.
4. `20260722100000_g2_phase13_reusable_customer_pricelist.sql` defines the
   canonical writers `save_reusable_pricelist_with_rules(...)` and
   `save_customer_with_pricelist(...)`. It validates active sale Product-UOM,
   permits `FIXED_PRICE >= 0`, records Pricelist/Customer audit, and enforces
   tenant and role authority.
   The forward configuration migration cannot impersonate an authenticated
   UI actor, so it reproduces these proven table invariants directly inside one
   guarded transaction, selects the existing linked Super Admin audit actor,
   and writes both canonical master-audit tables.
5. `20260729100000_g4_phase5_cashier_pricelist_override.sql` resolves the
   assigned Customer Pricelist ahead of Global pricing and returns its exact
   fixed unit price.
6. PWA Catalog selects `activeCustomer.defaultPricelistId` in `pwa/src/App.tsx`
   and submits the chosen/automatic Pricelist to the server-side repricer.

## Production read-only evidence (2026-11-03)

The configured Supabase target was read with service-role authority using only
REST `GET` requests; credentials were not printed or stored.

- Company: `KGFF / Kidul Gunung Frozen Food`, active, exactly one row.
- Customer: `KGS003 / SALES KGS`, active, regular (not system), master version
  `2`, current `default_pricelist_id = NULL`, exactly one matching row.
- Authoritative SQL-editor preflight: `78` active,
  sale-allowed Product-UOM rows. Four already have a zero base sale price, but
  all 78 still need explicit zero rules because Customer Pricelist missing-rule
  fallback would otherwise expose the Product-UOM base price.
- Existing Pricelists: `Harga Umum`, `Agen`, `Cahyo`, and `Reseller`; no existing
  zero-price Sample Pricelist was found.

## Impact map

### Direct impact

- One new KGFF Pricelist, proposed code `SAMPLE-SALES-KGS`, scope `CUSTOMER`,
  active, all stores, not Global default.
- Exactly 78 active `FIXED_PRICE = 0` rules at the proven preflight state, one
  for every current active
  sale-allowed KGFF Product-UOM.
- Customer `KGS003 / SALES KGS` changes from Global-default pricing to that
  Customer Pricelist for new transactions.

### Downstream impact

- New Drafts for SALES KGS resolve included Product-UOM prices to zero and keep
  immutable Pricelist/rule snapshots.
- Existing Drafts and Posted Sales must not be rewritten.
- Product base prices, Global and other Customer Pricelists remain unchanged.
- Adding a new sale-allowed Product-UOM later does **not** automatically add a
  zero rule; without a rule it falls back to Product-UOM price. A controlled
  Pricelist update is required for future catalog additions.

### Stock, Payment, and Finance boundary

- Pricelist configuration alone creates no Stock, FIFO, Payment, session, or
  Finance effect.
- The current non-Tempo POS posting core rejects a zero-total checkout because
  it requires at least one positive Payment leg. Therefore this Pricelist may
  be created/assigned first, but it is **not yet an operational Sample flow**.
- The approved future Sample behavior needs a separate audited change: no
  Payment row, Stock/FIFO outbound, and Finance `Debit Sample/Promotion Expense
  / Credit Inventory`. It must not use the POS Expense cash-disbursement flow.

### Compatibility and risk

- Same-Company enforcement: KGFF only.
- Other Customers and Companies: unchanged.
- Historical Sales: unchanged.
- Exact retry/idempotency: the rollout must reject a conflicting code/name and
  be safely rerunnable only after verifying the exact existing target identity.
- Concurrency: Pricelist creation and Customer assignment must be one database
  transaction with locked target rows or canonical RPC transaction semantics.
- Rollback: unassign the Customer first, then deactivate the Pricelist; never
  rewrite historical Sale snapshots.

## Database state classification

- Object/data state: defining tables, columns, relationships, and live target
  data are proven through repository definitions plus the read-only production
  inventory above.
- Migration ledger and data state: user-provided consolidated SQL-editor
  preflight proves all five dependencies installed, target absent, exact
  Company/Customer identity, 78 unique active sale Product-UOM rows, canonical
  runtime objects present, and zero active Finance/offline queues.
- Overall state: `NOT_INSTALLED`, consistent, and eligible for guarded Phase B.
- The migration re-enumerates the active catalog inside its transaction and
  rejects any missing, duplicate, extra, inactive, or cross-Company rule.

## Test matrix for the later rollout

1. Exact KGFF Company and exact regular active SALES KGS Customer.
2. All active sale UOMs covered once; no inactive/non-sale/cross-Company rule.
3. Automatic resolver returns zero for SALES KGS and normal price for another
   KGFF Customer.
4. Explicit Global override behavior remains the existing approved behavior.
5. Existing Draft/Posted rows unchanged.
6. Retry does not duplicate header/rules/audit.
7. Other Company and Walk-In remain unchanged.
8. Zero-total checkout remains blocked until the separate Sample transaction
   behavior is implemented and tested across Stock/FIFO/Finance.

## Production closing evidence (2026-11-03)

- User-confirmed postflight: migration ledger `1`, header `1`, assigned
  Customer `1`, active sale Product-UOM `78`, active zero rules `78`, Pricelist
  CREATE audit `1`, and Customer assignment audit `1`; all mandatory rows PASS.
- User-confirmed rollback-only resolver behavior succeeded.
- Proven status: `DATABASE LIVE / POSTFLIGHT PASS / BEHAVIOR PASS`.
- Not proven: authenticated POS smoke, zero-total checkout, Stock/FIFO Sample
  posting, Sample/Promotion Expense Journal, and UAT.
