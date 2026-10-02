# Sales Export Net Detail — Impact Map

## Outcome

The Sales Invoice XLSX gains `Detail Penjualan Bersih`. Existing gross Invoice
sheets remain immutable audit history; the new sheet is the operational source
for quantity reconciliation after cancellation and Customer Return.

## Direct impact

- `public.export_sales_documents_with_reconciliation(date,date)` adds the
  `netSalesLines` member without removing or changing existing members.
- A private read-only core resolves current net quantities by exact lineage.
- The XLSX renderer adds one sheet and summary metadata.

Retail Return is linked by Sale/detail identity. Backoffice Return is linked by
the persisted Invoice allocation and `invoice_line_id`; SKU/name matching is
not used to assign a Return to an Invoice.

## Quantity contract

All reconciled quantities use base UOM:

- `Qty Penjualan Bersih = max(Qty Invoice - Qty Batal - Qty Retur, 0)`;
- `Qty Keluar Bersih Stok = max(Qty Keluar Stok - Qty Reversal Stok - Qty
  Retur Masuk Stok, 0)`;
- `DESTROY` and no-physical Return reduce net Sales but never pretend that
  usable Stock returned;
- the date range selects source Invoices; valid Return/reversal state is the
  current state when the export is generated.

Retail Stock columns use posted Stock Movement. Backoffice Stock columns use
canonical accepted Invoice quantity because a Backoffice Invoice line has exact
SO-line quantity allocation but no persisted one-to-one Stock Movement ID.
`Dasar Qty Stok` exposes this distinction instead of hiding it.

## Downstream and regression risk

- Existing consumers of `documents` and `reconciliation` remain compatible.
- Workbook size and RPC work increase with the selected Invoice range.
- Draft Backoffice Invoice rows are marked `BELUM_FINAL`.
- A Return allocated to a Draft Backoffice Invoice is not subtracted twice:
  that canonical flow already reduces the Draft line itself. Only
  `POSTED_INVOICE` allocations are deducted from immutable posted lines.
- Backoffice received Return quantity that has not yet been allocated to an
  Invoice is intentionally not guessed onto an Invoice row; it remains visible
  in the existing `Retur Customer` sheet until allocation exists.

## No mutation

No Invoice, SO, Return, Stock, FIFO, Purchase, Payment, Cashier Session,
Financial Event, Journal, COA, or audit business row is written. The only
database writes during rollout are the routine definition and migration ledger.

## Verification boundary

- preflight validates dependencies, exact allocation lineage, queue boundary,
  and object absence;
- behavioral test validates every active Company, authenticated composite RPC,
  arithmetic, nonzero runtime data, and the corrected SMS duplicate-Sale case;
- postflight validates permissions, definitions, arithmetic, and Company scope;
- authenticated XLSX download and user reconciliation remain manual smoke/UAT.

## Rollback / forward fix

Before client deployment, restore the prior wrapper definition, drop
`private.get_sales_export_net_detail_core(uuid,date,date)`, and remove only the
`20261002100000` ledger row. After client deployment, use a forward fix so the
expected `netSalesLines` member is not removed while the client is live.
