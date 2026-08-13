# Inventory Surat Jalan Authority Rollout

**Status:** LOCAL READY — manual Supabase rollout pending  
**Migration:** `20260813150000`  
**Permission:** `inventory.delivery_documents`

## Outcome

- POS tetap dapat mencetak Invoice dan Surat Jalan final melalui open-session
  Sale authority;
- Backoffice Sales hanya menampilkan Invoice dan memakai
  `sales.sales_documents` `VIEW/EXPORT`;
- Backoffice Inventory menampilkan Surat Jalan quantity-only dan memakai
  `inventory.delivery_documents` `VIEW/MANAGE`;
- Warehouse Admin dapat menyiapkan, print, dispatch, deliver, atau cancel sesuai
  capability tanpa memperoleh harga, payment, Customer Balance, atau Invoice
  payload;
- tabel, UUID, nomor `SJ/YYYY/MM/NNNNNN`, Sale source, snapshot, dan lifecycle
  existing tidak berubah;
- print/status Surat Jalan tidak membuat Stock Movement, Payment, Financial
  Event, atau Journal kedua.

## Urutan Manual

1. Jalankan seluruh
   `supabase/diagnostics/inventory_delivery_document_authority_preflight.sql`.
2. Berhenti bila ada `BLOCKER`. `SETUP` adalah target migration.
3. Jalankan
   `supabase/migrations/20260813150000_inventory_delivery_document_authority.sql`.
4. Restart Backoffice.
5. Jalankan
   `supabase/diagnostics/inventory_delivery_document_authority_postflight.sql`.
6. Hanya jika seluruh row `PASS`, jalankan
   `supabase/tests/inventory_delivery_document_authority_tests.sql`.
7. Rerun postflight, lalu ACP-7 dan PRD-1 preflight terbaru.

## Smoke

- Owner/Admin/Store Manager/Warehouse Admin melihat `Inventory → Surat Jalan`;
- `LIHAT_SAJA` dapat list/detail/print tetapi status ditolak;
- `OPERASIONAL` dapat menjalankan lifecycle valid;
- Finance/Accounting melihat `Sales → Invoice Penjualan` tanpa memperoleh menu
  Surat Jalan dari Inventory;
- role tanpa Invoice tidak dapat membuka API Invoice walau memiliki Surat Jalan;
- Company A tidak dapat melihat/mengubah Surat Jalan Company B;
- POS post Delivery tetap menawarkan print Invoice dan Surat Jalan;
- Pickup tetap tidak membuat Surat Jalan.

## Compatibility / Forward Fix

Public POS RPC tidak berubah. Public Backoffice delivery wrapper lama tetap ada,
tetapi sekarang memerlukan permission Inventory sehingga direct call tidak
menjadi bypass. Jika UI cutover bermasalah, jangan membuka table grant; perbaiki
consumer/API atau set key baru `SHADOW` melalui forward migration terkontrol.
