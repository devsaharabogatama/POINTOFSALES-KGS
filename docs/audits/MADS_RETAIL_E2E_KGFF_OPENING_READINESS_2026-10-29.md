# MADS Retail E2E and KGFF opening-readiness audit — 2026-10-29

## Scope and status

This audit covers local Backoffice/POS PWA build and browser evidence, prior
user-confirmed KGFF Production postflights, and the opening-balance workflow
actually present in the repository. The agent did not access or mutate
Production.

- `LOCAL BUILD PASS`;
- `LOCAL CLIENT E2E 7/7 PASS`;
- `LOCAL CONTRACT REGRESSION PASS`;
- `KGFF DATABASE LIVE / POSTFLIGHT PASS` from prior user-provided evidence;
- `CURRENT PRODUCTION FIVE-GATE POSTFLIGHT PASS`;
- `AUTHENTICATED KGFF UI SMOKE PENDING`;
- `OPENING STOCK RUNTIME AVAILABLE`;
- `OPENING AR/AP/CUSTOMER DEPOSIT/GL RUNTIME NOT AVAILABLE`;
- `OPENING BALANCE NOT STARTED`.

## Impact map

Direct impact:

- added an isolated Playwright harness for public Backoffice, POS PWA and a
  KGFF-shaped Retail sale client flow;
- fixed Backoffice login label associations (`htmlFor`/`id`) found by the
  browser test;
- corrected the Sales Return UI contract harness to follow the current
  navigation catalog and wording.

Downstream consumers inspected include Retail Draft, pricing, Customer,
Pricelist, payment, confirmation, session close, Return, Expense, Stock
Request, Goods Receipt, Supplier Return, Stock Opname, Cash Deposit, Backoffice
navigation and guarded Opening Stock API/UI.

No Stock, reservation, FIFO, payment, Cashier Session, Finance Event, Journal,
master data or audit row was mutated. Browser Retail requests were intercepted
with deterministic mocks and never reached Supabase.

Regression risks not proved locally:

- server/database behavior with a real authenticated KGFF user;
- RLS/permission behavior for real Cashier, Manager and Finance roles;
- concurrency/retry behavior against the live database;
- current Production drift since prior postflight outputs;
- cross-device PWA install/offline recovery and physical printer behavior.

## Local evidence

- Backoffice lint PASS with zero errors and five pre-existing warnings.
- Backoffice build and TypeScript PASS; 88 static pages.
- POS PWA lint/build PASS; PWA generated; existing main-chunk warning remains.
- `qa-e2e/npm.cmd test`: 7/7 PASS using system Chrome.
- Invoice correction command: 43/43 PASS.
- Delivery progressive/bulk, Finance mapping, Goods Receipt, Retail history,
  Sales Return UI and searchable master contracts: PASS.
- Sales Return contract update was a `TEST HARNESS FIX`; no business assertion
  was removed.

The browser sale test proves client orchestration only: login fixture, KGFF
catalog, Customer, Pricelist, Cash method, price preview, Draft save and Order
confirmation call canonical RPC names. It is not database-live E2E.

## KGFF master/configuration evidence

Prior user-provided Production postflights prove this installed state:

| Area | Proven state |
|---|---|
| Location | 1 Store, 4 Warehouses, 1 active POS terminal |
| Finance | 37 user-owned COA, 92 direct mappings, 14 fallbacks, Retail runtime active |
| Product | 9 Categories, 6 UOM, 74 Products, 76 Product-UOM, 0 Bundles |
| Tax | 1 Draft PPN11 version; Tax features intentionally disabled |
| Commercial | 207 Customers, 5 Customer Categories, 1 Supplier, 1 Product-Supplier |
| Pricing/payment | 4 Pricelists, 10 rules, 4 Payment Methods |
| Retail policy | `RETAIL_CONFIRM_INVOICE`, negative stock enabled, 4 non-Tax features |
| Opening/business effect | zero Stock/FIFO, opening balance, Event and Journal effect at clone closure |

The user reran all five current SELECT-only Production gates on 2026-10-29.
Location, Finance, Product/Tax, Commercial/Policy and session-procurement
diagnostics all returned PASS for every non-INFO row. The current database
therefore remains consistent and empty of Stock/FIFO, business documents,
opening effects, Events and Journals. Before opening, perform the authenticated
read-only KGFF UI smoke in
`docs/runbooks/KGFF_KGS_MASTER_CONFIGURATION_CLONE.md`.

Operational setup still requiring human confirmation:

- KGFF legal/company profile and KGFF bank identity, which were not copied;
- Cashier/Manager/Finance memberships and permissions;
- POS terminal device pairing; cloned terminal device identifier is empty;
- whether KGFF must activate Tax; current PPN11 is Draft and Tax is OFF;
- real-role visibility of Product prices, Customers and Payment Methods;
- procurement remains manual under previously proven settings.

## Opening-balance data required from users

Users provide business identities only—never UUIDs, role codes, mapping keys or
future system document numbers.

1. Cut-off control: cut-off date, Company, source report, owner, lock time and
   manual totals for trial balance, Inventory, AR, AP, Customer deposit, Cash,
   Bank, fixed asset, Tax and Equity.
2. Opening Stock: Warehouse, effective date, Product SKU, Base UOM, physical
   quantity, HPP per Base UOM, optional zero-cost reason and notes.
3. Outstanding receivables: Customer, legacy invoice/reference, invoice and due
   dates, currency, original/open amount, Store and evidence.
4. Outstanding payables: Supplier, legacy invoice/reference, invoice and due
   dates, currency, original/open amount, purchase reference and evidence.
5. Unapplied Customer deposits: Customer, legacy reference, deposit date,
   currency, open amount, Store and evidence.
6. Opening trial balance/GL: cut-off date, account code, debit or credit,
   optional Store/Warehouse/Customer/Supplier dimensions, description and
   evidence. Cash/Bank use their human-readable COA codes.
7. Reconciliation: manual/system amount, difference, status, evidence, reviewer
   and timestamp for every required control.

AR, AP and Inventory control values must not be posted twice through both
detail and GL.

## Posting boundary

- `20_opening_stock.csv`: guarded workflow available via **Inventory > Stok
  Awal**.
- `21_opening_receivable.csv`: data collection only; runtime pending.
- `22_opening_payable.csv`: data collection only; runtime pending.
- `23_opening_customer_deposit.csv`: data collection only; runtime pending.
- `24_opening_gl.csv`: data collection only; runtime pending.

Do not convert outstanding balances into fake Sales, Purchases, Goods Receipts,
Payments or direct table writes. Full opening go-live remains blocked until the
missing subledger/GL workflows exist or an approved guarded design is built and
verified.

## Next safe gate

1. perform authenticated read-only KGFF UI smoke without opening a Cashier
   Session or creating a transaction;
2. collect the seven human-readable datasets above;
3. reconcile and post Opening Stock only through the existing workflow;
4. hold AR/AP/Customer Deposit/GL as reviewed input data until guarded runtimes
   exist.
