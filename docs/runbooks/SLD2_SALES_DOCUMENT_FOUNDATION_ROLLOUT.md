# SLD-2 Sales Document Foundation Rollout

**Status:** READY FOR MANUAL DATABASE ROLLOUT  
**Tanggal:** 2026-08-11  
**Scope:** immutable Sales Invoice snapshot dan Surat Jalan khusus `DELIVERY`

## Hasil preflight yang membuka gate

Output live SLD-1 tidak mempunyai `BLOCKER`. Tiga row `REVIEW`/`BACKFILL` dan
dua row `SETUP` adalah scope migration ini:

- tiga Customer belum mempunyai identitas delivery lengkap; recipient tetap
  wajib direview saat memilih `DELIVERY`;
- satu Store belum mempunyai print identity lengkap; snapshot tetap menyimpan
  nama/alamat yang tersedia tanpa menciptakan data palsu;
- sembilan Sale POSTED (tujuh online, dua offline) memerlukan snapshot formal;
- empat relation dan enam kolom fulfillment belum ada;
- logo yang sudah masuk snapshot final tidak boleh dihapus saat branding
  diganti atau dilepas.

Seluruh invariant Sale, Return, Offline, Bundle, tenant, browser-write, dan
single Financial Event pada preflight berstatus `PASS`.

## Artefak

1. Migration:
   `supabase/migrations/20260811130000_sld_phase2_sales_document_foundation.sql`
2. Postflight:
   `supabase/diagnostics/sld_phase2_sales_document_postflight.sql`
3. Behavioral test rollback-safe:
   `supabase/tests/sld_phase2_sales_document_tests.sql`

## Urutan manual wajib

Jalankan pada Supabase SQL Editor dalam urutan berikut. Jangan menjalankan
behavioral test sebelum migration dan postflight pertama lulus.

1. Jalankan migration `20260811130000_sld_phase2_sales_document_foundation.sql`.
2. Jalankan `sld_phase2_sales_document_postflight.sql`.
3. Semua row selain inventory `INFO` wajib `PASS`; tidak boleh ada `FAIL`.
4. Jalankan `sld_phase2_sales_document_tests.sql`.
5. Pastikan notice terakhir:
   `TEST PASSED: Invoice and delivery-only Surat Jalan are tenant-safe, immutable, idempotent, audited, and zero-extra-effect.`
6. Jalankan kembali postflight SLD-2; seluruh row non-`INFO` harus tetap
   `PASS`.

## Regression minimum

Setelah behavioral SLD-2 lulus, jalankan kembali:

1. `supabase/tests/g4_phase4_atomic_sale_runtime_tests.sql`;
2. `supabase/tests/g4_phase12_offline_sync_tests.sql`;
3. `supabase/tests/g4_phase56_customer_balance_tender_tests.sql`;
4. `supabase/tests/g4_phase26_sales_return_foundation_tests.sql`;
5. `supabase/diagnostics/g3_phase14_inventory_core_exit_preflight.sql`.

Jangan memperbaiki fixture regression dengan menghapus data operasional atau
menonaktifkan constraint. Laporkan error lengkap bila ada.

## Efek yang memang dibuat

- setiap Sale POSTED memperoleh tepat satu `sales_invoice_snapshots`;
- sembilan Sale historis memperoleh provenance `LEGACY_CUTOVER`;
- Sale `PICKUP` tidak memperoleh Surat Jalan;
- Sale `DELIVERY` memperoleh tepat satu `sales_delivery_documents` dan line
  snapshot dengan nomor `SJ/YYYY/MM/NNNNNN`;
- print dan lifecycle Delivery dicatat pada append-only audit;
- replace/remove Company logo mempertahankan object lama bila sudah dirujuk
  dokumen final.

## Efek yang dilarang

Migration/backfill dan lifecycle dokumen tidak boleh:

- membuat atau mengubah `stock_movements`, FIFO, atau `product_stocks`;
- membuat Payment baru atau mengubah nilai Sale/Tax/AR;
- membuat Financial Event atau Journal tambahan;
- membuat Surat Jalan untuk `PICKUP`;
- memberi authenticated browser direct mutation atas tabel dokumen;
- mengizinkan baca/update lintas Company.

## Compatibility

- `sales_headers.invoice_no` tetap nomor Invoice canonical;
- `receipt_snapshot` dan thermal receipt PWA tetap dipertahankan;
- `sj_required`, `sj_no`, dan `sj_status` legacy tetap disinkronkan sebagai
  compatibility fields;
- public Post Sale signature tidak berubah;
- UI dan printable formal baru dibuka pada SLD-3 setelah gate database ini
  user-verified.

## Recovery

Migration dibungkus satu transaction; error sebelum `COMMIT` harus rollback
seluruh perubahan. Setelah migration sukses, gunakan forward-fix; jangan drop
snapshot/audit final dan jangan edit migration yang sudah applied. Jika
postflight atau behavior gagal, hentikan SLD-3 dan kirim error lengkap beserta
nama check yang gagal.
