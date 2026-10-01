# Delivery Return Status Overlay - Impact Audit

## Outcome

Inventory **Surat Jalan** menampilkan indikator Return yang terhubung tanpa
mengubah lifecycle final Delivery. Daftar menampilkan badge ringkas dan detail
menampilkan nomor/status Return serta quantity diajukan, diterima, masuk stok,
dan dihancurkan.

## Execution path aktif

- Retail/POS Delivery list: `DeliveryDocumentView` ->
  `/api/inventory/delivery-documents` ->
  `public.get_inventory_delivery_documents(date,date)`.
- Backoffice Delivery list: `DeliveryDocumentView` ->
  `/api/inventory/backoffice-delivery-orders` ->
  `public.get_inventory_backoffice_delivery_orders(date,date)`.
- Return source:
  `backoffice_sales_returns` + `backoffice_sales_return_receipts`.
- Retail lineage: `backoffice_sales_returns.retail_sales_id` ->
  `sales_delivery_documents.sales_id` (exact Delivery source).
- Backoffice lineage: `backoffice_sales_returns.sales_order_id` ->
  `backoffice_sales_delivery_orders.sales_order_id` (SO-level source).

## Impact map

### Direct impact

- Additive authenticated read RPC
  `public.get_inventory_delivery_return_overlays(date,date)`.
- Additive Inventory API route `/api/inventory/delivery-return-overlays`.
- Surat Jalan list/detail UI receives a derived `returnDocuments` overlay.

### Downstream impact

- None. The overlay does not write Delivery, SO, Invoice, Return, receipt,
  Stock Movement, FIFO, Payment, Financial Event, Journal, or COA mapping.
- Existing print/PDF payload stays unchanged. Return status is operational UI
  context and is not silently added to historical printed documents.

### Attribution boundary

- A retained Retail Return points to one Retail Sale, while a Retail Sale has
  one canonical Delivery document. The overlay may say **Retur terkait DO**.
- A Backoffice Return currently points to an SO/line, not to one exact Delivery
  Order. One SO can have INITIAL/BACKORDER Delivery documents. Every related DO
  may therefore display **Retur pada SO ini**, but the UI must not claim that a
  particular DO was the physical source unless a future exact allocation is
  persisted.

### Compatibility and regression risk

- Existing Delivery status and action eligibility remain authoritative.
- Canceled Returns remain visible as history but are visually separated from
  active Return processing.
- Multiple/partial Returns are shown as separate documents; totals are never
  inferred by replacing the Delivery quantity.
- Tenant and permission scope are enforced by the same active-Company and
  `inventory.delivery_documents:VIEW` authority used by the Delivery workspace.

## Verification matrix

1. Retail Delivery with retained-Retail Return is linked by exact `sales_id`.
2. Backoffice Delivery with Return is labeled as SO-level attribution.
3. Partial receipt shows requested and received quantities independently.
4. RESTOCK and DESTROY totals are exposed independently.
5. Canceled Return remains visible but is not represented as active.
6. Delivery without Return receives no badge/panel.
7. Cross-Company rows cannot enter the payload.
8. Invalid date range fails closed.
9. Read operation creates no Stock/Finance/transaction mutation.

## Rollback / forward-fix

- Safe rollback: remove the client request/UI overlay and revoke/drop the new
  additive RPC. No data rollback or backfill is required.
- Do not add a persisted `return_status` column to Delivery; that would create
  stale duplicated state.

