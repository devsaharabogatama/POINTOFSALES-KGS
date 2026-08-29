# ODR-4 Procurement Demand Preflight

Tahap ini hanya mengaudit kesiapan demand Purchasing berbasis shortage
reservation. Jalankan melalui Supabase SQL Editor:

1. `supabase/diagnostics/odr_phase4_procurement_demand_preflight.sql`.

File tersebut hanya satu pernyataan `SELECT`; tidak mengubah schema, data,
permission, Stock Request, Supplier Order, reservation, stok, atau Finance.

## Keputusan hasil

- `BLOCKER`: jangan lanjut ke migration ODR-4. Kirim seluruh output untuk
  diperiksa.
- `PASS`: invariant existing aman.
- `REVIEW`: collision runtime lama yang memang menjadi target cutover ODR-4;
  nilainya perlu dibaca sebelum desain migration dibekukan.
- `SETUP`: schema/runtime ODR-4 belum tersedia dan merupakan kondisi expected
  sebelum migration.
- `INFO`: inventaris volume live, bukan kegagalan.

ODR-4 wajib mempertahankan Stock Request manual dan request stok-minus posted
sebagai histori. Demand baru bersumber dari shortage reservation terbuka dan
memiliki satu identitas per Company, Store, Warehouse, dan sesi kasir. Hanya PO
`DRAFT` yang boleh disinkronkan. PO `CONFIRMED`, `PARTIALLY_RECEIVED`, atau
`RECEIVED` tidak boleh diedit otomatis; perubahan menjadi delta/amendment yang
dapat ditinjau Purchasing.

Jangan menjalankan migration ODR-4 sebelum seluruh `BLOCKER` bersih dan scope
`REVIEW` sudah dinilai.

`supplier_order_request_allocation_reconciliation` hanya menilai allocation
yang sudah final pada PO `CONFIRMED/PARTIALLY_RECEIVED/RECEIVED`. Allocation PO
`DRAFT` adalah planning scope yang masih boleh berubah dan dilaporkan terpisah
sebagai `draft_supplier_order_allocation_scope REVIEW`; ODR-4 wajib
merekonsiliasinya sebelum PO dikonfirmasi.
