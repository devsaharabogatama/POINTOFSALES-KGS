# Backoffice Quotation/Sales Order Persistence Foundation

**Status:** LOCAL READY / DEVELOPMENT DATABASE NOT RUN / FEATURE OFF

## Scope

Migration `20260908110000` membuat persistence terisolasi:

- `backoffice_sales_orders`;
- `backoffice_sales_order_lines`;
- `backoffice_sales_order_operations` untuk exact-operation identity;
- `backoffice_sales_order_audit` yang append-only.

Tidak ada public RPC, Company enablement, atau UI pada fase ini. Tidak ada row
`sales_headers`, Reservation, DO/SJ, Invoice, Payment, Stock/FIFO/Movement,
Financial Event, Journal, atau posting queue yang dibuat.

## Impact map

- Direct: empat relation baru, constraint tenant/lifecycle/date/amount,
  RLS, privilege service-role, dan immutable history trigger.
- Downstream: runtime Quotation/SO berikutnya akan menjadi satu-satunya writer.
- Compatibility: POS dan seluruh consumer `sales_headers` tidak berubah.
- Concurrency: operation identity `(company_id,operation_id)` disediakan;
  enforcement request hash dan stale version dilakukan oleh runtime berikutnya.
- Rollback: sebelum ada row, empat relation dan private trigger function dapat
  dihapus terkontrol. Setelah ada row gunakan forward-fix, bukan drop.

## Gate Development

1. Jalankan `backoffice_sales_order_foundation_preflight.sql`; hentikan pada
   BLOCKER.
2. Terapkan migration hanya ke isolated Development.
3. Jalankan `backoffice_sales_order_foundation_postflight.sql`.
4. Siapkan fixture master/customer/product terisolasi.
5. Runtime dan behavioral test dibuat pada migration terpisah.

PASS schema dengan row nol bukan behavioral PASS. Status client, authenticated
smoke, regression, dan UAT tetap pending.
