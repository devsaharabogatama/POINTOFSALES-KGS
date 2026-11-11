# Backoffice Draft Invoice Detail Regression Audit — 2026-11-10

## Classification and scope

- Classification: `SCHEMA_OR_MIGRATION_CHANGE` (`PRODUCT FIX`).
- Environment in which the defect was reproduced: isolated local Docker
  Supabase and local Backoffice only.
- Production access or mutation: none.
- Expected outcome: a Backoffice Invoice with status `DRAFT` must remain
  readable/editable and must not require the Posted-only unified revision
  context. Posted regular Invoice revision/payment behavior must remain
  unchanged.

## Runtime evidence and source of truth

The local UAT created `DINV-20261110-0000000021` for
`SO-20261110-0000000019`. Database evidence before opening the detail proved:

- status `DRAFT`, total Rp30.000, `financial_event_id IS NULL`;
- zero Finance Event, zero Journal, zero AR open item;
- Draft allocation 2 base units, Stock/FIFO both remain 98.

The UI list shows the Draft. Clicking its row calls
`GET /api/sales/backoffice-invoices/1610f253-e787-4e2d-9311-1012fa814a25`,
which returned HTTP 500 with `POSTED_REGULAR_INVOICE_REQUIRED`. No posting or
other mutation occurred.

Defining sources:

- `backoffice/src/components/BackofficeSalesInvoiceView.tsx` calls the detail
  route for both Draft and Posted Invoice.
- `backoffice/src/app/api/sales/backoffice-invoices/[id]/route.ts` first calls
  `public.get_backoffice_sales_invoice_ui(uuid)` and, for Finance VIEW users,
  `public.get_backoffice_sales_invoice_payment_context(uuid)`.
- `supabase/migrations/20260911150000_backoffice_sales_invoice_client_activation.sql`
  defines the base UI function and its Draft read behavior.
- `supabase/migrations/20260928110000_backoffice_posted_invoice_price_correction.sql`
  defines the base payment context, including Draft status
  `NOT_APPLICABLE`.
- `supabase/migrations/20261006140000_backoffice_unified_posted_invoice_revision.sql`
  wraps both consumers and unconditionally calls
  `public.get_backoffice_invoice_revision_context(uuid)`.
- The same migration explicitly requires status `POSTED` and type `REGULAR`
  in that revision context, raising `POSTED_REGULAR_INVOICE_REQUIRED`
  otherwise.

Active local object evidence:

- `get_backoffice_sales_invoice_ui(uuid)` MD5:
  `ae46ab9d5fe5d1d9b34ddc90cf807bdb`;
- its preserved base function MD5:
  `b43376b77274176c35de37d8bed2c143`;
- `get_backoffice_sales_invoice_payment_context(uuid)` MD5:
  `dbe5b9307343bd03e6ea61a36490c692`;
- its preserved base function MD5:
  `9d107065f132ac27bc889197862b51c3`.

The local database is a documented schema-only production-shaped snapshot.
Its fixture inserts selected immutable ledger markers but currently omits the
`20261006140000` marker while the exact wrapper/base objects exist. For this
fix the initial state is therefore `PARTIAL/INCONSISTENT` until the local-only
bootstrap marker is added from that immutable migration identity. Production
state remains `UNKNOWN` and is outside this local task.

## Active call chain

1. SO detail opens Invoice workspace.
2. Invoice workspace lists the Draft correctly.
3. Clicking the Draft calls the Next detail route.
4. The route calls the effective UI RPC.
5. The effective UI RPC calls the Posted-only revision context without first
   partitioning Draft/non-regular status.
6. The exception prevents Draft detail/edit and therefore prevents normal
   posting through the client.

The payment-context wrapper has the same unconditional Posted-only call and
would fail next even if the UI wrapper alone were corrected.

## Impact map

### Direct impact

- Effective Invoice UI read RPC.
- Effective Invoice payment-context read RPC.
- Backoffice Draft Invoice detail/edit/post entry point.

### Downstream impact

- Posted regular Invoice revision identity, total, schedules, and refund
  presentation.
- Posted down-payment/non-regular Invoice read compatibility.
- Customer Receipt entry point and AR open-item runtime after posting.

### Explicitly unaffected

- SO, Delivery, Reservation, Stock, FIFO/HPP movement and their existing rows.
- Invoice posting mutation, accounting mapping, Finance Event/Journal writer,
  AR registration writer, payment allocation writer, Return/Credit Note, POS
  Retail, other Companies, and historical Posted data.

### Tenant/security/concurrency/idempotency

- Existing active-Company and permission checks remain in the preserved base
  functions and Posted-only revision context.
- The fix is read-only function partitioning; it adds no mutation,
  transaction, concurrency, retry, or idempotency path.
- Migration remains guarded by advisory lock, ledger/object checks, and a new
  immutable version. Existing live migration files remain unchanged.

## Fix design

- For each effective wrapper, call the preserved base function first.
- Resolve the Invoice status/type inside the active Company.
- If it is not a Posted regular Invoice, return the base payload unchanged.
- Only Posted regular Invoice calls the unified revision context and applies
  the existing merge logic.
- Keep the Next route unchanged because its existing behavior legitimately
  requests a base payment context for Draft (`NOT_APPLICABLE`).

## Regression matrix

| Case | Required proof |
|---|---|
| Draft regular Invoice | UI RPC returns base Draft, payment context returns `NOT_APPLICABLE`, no Event/Journal/open item |
| Posted regular Invoice | unified revision fields still merge; payment/revision context unchanged |
| Posted down-payment Invoice | returns base payload; no Posted-regular exception |
| Wrong Company | existing tenant denial preserved |
| Missing permission | existing server-side permission denial preserved |
| Exact repeated reads | stable, no writes or version changes |
| Existing Draft from local UAT | detail opens, can then post through canonical UI |
| Post result | Invoice Event/Journal and AR open item reconcile; Stock/FIFO remain 98 |
| Customer Receipt and open credit | run only after Invoice post succeeds |
| POS Retail/Backoffice Return | no changed function/caller; regression suite remains required |

## Rollback / forward-fix

- Do not edit or rerun `20261006140000`.
- Ship a new forward migration that replaces only the two effective read
  wrappers and records its own ledger row.
- Rollback is another forward migration restoring the prior definitions; no
  data rollback is needed because the functions are read-only.

## Current status

- Root cause: proven.
- Product fix: not yet implemented at the time of this audit entry.
- Local UAT: frozen at Draft detail failure.
- Production: untouched.
