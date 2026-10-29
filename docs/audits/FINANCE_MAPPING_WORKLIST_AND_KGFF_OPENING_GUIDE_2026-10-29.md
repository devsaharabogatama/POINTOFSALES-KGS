# Finance mapping worklist and KGFF opening guide — 2026-10-29

## Outcome and status

The existing Company-scoped Finance mapping coverage page is now an operational
worklist. It does not select or activate any account automatically.

- `LOCAL READY` for the Backoffice client change;
- no schema, migration, Production data, mapping, Journal, Event, Stock or FIFO
  mutation was made;
- client deployment, authenticated smoke and user UAT remain pending.

## Evidence-first impact map

Direct impact:

- `FinanceMasterView` defaults the coverage worklist to unresolved rows;
- Finance can filter unresolved, conditional, required, optional or all rows;
- search covers process, category, function, account name and account code;
- `Isi mapping` opens the existing versioned rule editor with the exact
  category and account function preselected;
- Finance still chooses the compatible account, status and effective period.

Downstream impact:

- saving continues to call the existing `save_transaction_account_rule` path;
- existing server-side tenant, role, account compatibility, period overlap and
  version guards remain authoritative;
- effective mapping changes may affect new or not-yet-posted events according
  to the existing resolver contract;
- Posted Journals remain immutable.

Not changed:

- system-event registry, Account Function contracts, COA, fallback rules;
- Finance queue/retry runtime;
- Stock, reservation, FIFO, Cashier Session, payment or historical Journal;
- KGFF database state or Production deployment.

Regression risks and unproved conditions:

- the new UI has not been smoke-tested with an authenticated Finance user;
- no Production mapping was saved;
- scenario-specific retry of an already-held event still requires its own
  authenticated smoke. A visible row does not prove that every source workflow
  is operational.

## Verification

- focused ESLint for `FinanceMasterView` and the completeness library: PASS;
- mapping completeness unit contract, including filter/search/readiness: PASS;
- Next.js production build and TypeScript, 88 routes: PASS;
- Playwright mapping worklist source contract: PASS;
- full `qa-e2e`: `11 PASS / 2 FAIL`. Both failures are the retained prior
  optional-field-label findings in the form-requiredness audit and are not
  caused by this change.

## KGFF opening entry guide

Final cutover decision: Opening Stock and Finance Opening Balance use effective
date `2026-10-31`; KGFF operational transactions start `2026-11-01`.

### Opening Stock — runtime available

1. Select Company `KGFF`.
2. Open **Inventory > Stok Awal**.
3. Choose **Buat Draft**.
4. Select the Warehouse and effective date `2026-10-31`.
5. Add each Product and enter quantity in its displayed Base UOM plus HPP per
   Base UOM. A zero HPP requires a reason; document notes are optional.
6. Save Draft, review total quantity and value, then Post with an authorized
   role. Draft has no Stock effect. Posting creates Stock, movement, FIFO and
   the Finance Event through the guarded runtime.

Before posting, create/open the October 2026 accounting period through
**Finance > Jurnal Keuangan > Periode** so the resulting Finance Event can be
posted by the canonical Finance runtime.

Freeze physical movement while the `2026-10-31` count is finalized. Do not
start KGFF operational transactions in the system before `2026-11-01`.

### AR, AP, Customer deposit and non-subledger GL — runtime unavailable

The repository and current cutover contract classify these datasets as
`MENUNGGU RUNTIME`:

- `21_opening_receivable.csv` for Customer-level outstanding invoices;
- `22_opening_payable.csv` for Supplier-level outstanding invoices;
- `23_opening_customer_deposit.csv` for unapplied Customer funds;
- `24_opening_gl.csv` for non-subledger balances and clearing closure.

They currently have no safe Backoffice opening-entry location. Do not use
Sales, Goods Receipt, Supplier Invoice, Payment or ordinary Manual Journal to
fake opening subledger balances, and do not write directly to tables. Doing so
would either create false operations or leave AR/AP detail different from GL.

The safe next implementation is a guarded, Company-scoped opening package with
Draft/review/post, exact party/account resolution, open-period validation,
balanced posting, immutable source snapshots, idempotent retry and
reconciliation controls. Until that package exists, collect and review the
human-readable CSV files only.

## Rollback

This change is client-only. Rollback is the narrow reversal of the coverage
filter/search/action UI and prefilled editor target. It does not require a
database rollback because no schema or data was changed.
