# ACP-5C Supplier Order Permission Preflight

## Tujuan

Mengaudit boundary `purchase.supplier_orders` sebelum enforcement. Tahap ini
hanya membaca metadata dan agregat; tidak mengubah schema, grant, permission,
Stock Request, Supplier Order, Goods Receipt, stock, FIFO, AP, Finance, atau
audit.

Boundary yang diperiksa sengaja dibagi:

- workspace Backoffice dan aksi Supplier Order memakai capability Purchase;
- Cashier membuat/submit Stock Request hanya melalui open session dan Store
  miliknya;
- Goods Receipt hanya menerima referensi order yang eligible untuk Store dan
  open session-nya;
- Supplier/Product-Supplier memakai reference RPC Purchase dari ACP-5B;
- Supplier Order sendiri tidak membuat stock, FIFO, AP, payment, atau journal.

## Urutan Eksekusi

1. Buka SQL Editor Supabase menggunakan owner/admin database.
2. Jalankan seluruh isi
   `supabase/diagnostics/acp_phase5c_supplier_order_permission_preflight.sql`.
3. Kirim seluruh baris `check_name,status,details`.
4. Berhenti bila ada `BLOCKER`.

`REVIEW` dan `SETUP` adalah inventory desain rollout berikutnya, bukan error
dan bukan izin untuk langsung menyalakan enforcement.

## Expected Sebelum Enforcement

- dependency G5 Supplier Order dan ACP-5B, catalog, schema, tenant, lifecycle,
  allocation, total, zero-effect, routine, dan direct-write boundary `PASS`;
- composed Backoffice read dan capability hook masih `SETUP`;
- direct-read cutover, Stock Request channel, Goods Receipt consumer, serta
  reference split muncul sebagai `REVIEW`;
- diagnostic tidak mengubah dokumen, stok, FIFO, AP, jurnal, grant, maupun
  permission status.

## Target Setelah Output Direview

Rollout berikutnya baru boleh menambahkan composed read ber-authority `VIEW`,
guard capability per aksi Supplier Order, cutover navigation/API, narrow
Cashier reference API, lalu menutup direct table read. Regression wajib
membuktikan Stock Request kasir, Goods Receipt, Purchase Return, tenant Store,
idempotent Confirm, allocation sisa, dan zero-effect Supplier Order tetap
berjalan. `purchase.purchase_returns` tidak ikut dienforce pada fase ini.
