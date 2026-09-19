# Backoffice Supplier Return Negative-Stock Forward Fix

**Status:** DATABASE LIVE + BEHAVIOR/POSTFLIGHT PASS. Jangan mengulang migration, behavior, atau postflight.

## Urutan Production

Berhenti pada error, `BLOCKER`, atau `FAIL` pertama.

1. Jalankan penuh
   `supabase/diagnostics/backoffice_purchase_return_negative_stock_preflight.sql`.
2. Pastikan seluruh baris `PASS`. Baris target harus menunjukkan exact
   `PO-20260825-0000000015`, commercial remaining positif, dan Warehouse
   negative-stock authority aktif.
3. Migration
   `supabase/migrations/20260919143000_backoffice_purchase_return_negative_stock_runtime.sql`
   sudah berhasil. Jangan dijalankan ulang; lanjut langsung ke behavior.
4. Jalankan penuh
   `supabase/tests/backoffice_purchase_return_negative_stock_behavior.sql`.
   Hasil akhir wajib satu baris `PASS`; fixture otomatis `ROLLBACK`.
   Ini regression khusus forward fix berukuran ringkas. File sengaja tidak
   memakai PL/pgSQL `SELECT ... INTO`, karena Supabase Dashboard dapat salah
   menganggap target variabel sebagai tabel baru dan menyisipkan RLS di tengah
   dollar-quoted block. Jangan gunakan E2E gabungan yang dipotong Dashboard.
5. Jalankan penuh
   `supabase/diagnostics/backoffice_purchase_return_negative_stock_postflight.sql`.
   Semua contract/reconciliation wajib `PASS`; inventory boleh `INFO`.
6. Deploy client yang memuat pesan dan label Return terbaru.

Jangan menjalankan migration dua kali. `MIGRATION_ALREADY_APPLIED` berarti cek
ledger/postflight, bukan menghapus ledger atau mengulang file.

## Authenticated smoke

1. Buka exact PO dan pilih Posted Goods Receipt dengan source FIFO nol.
2. Pastikan UI tetap menampilkan quantity Receipt yang belum diretur.
3. Buat Draft kecil, Approve, lalu Post satu kali.
4. Pastikan On Hand turun sesuai qty dan boleh negatif; batch lain tidak berubah.
5. Pastikan Stock Movement source-linked, Supplier Credit/AP split, dan Journal
   Return sama seperti flow existing.
6. Klik ulang Post: wajib menjadi idempotent replay tanpa effect ganda.
7. Jalankan preview AUTO RO: kekurangan baru wajib terlihat dari On Hand negatif.
8. Pada test terkontrol, terima replenishment berikutnya. Pastikan shortage
   berkurang, batch hanya menyisakan quantity setelah shortage, dan bila biaya
   berbeda terdapat jurnal Inventory/PPV yang seimbang.
9. Uji satu Retur POS/PWA existing untuk memastikan jalurnya tidak berubah.

## Kondisi sukses

- `LOCAL READY`: lint/build/static checks PASS.
- `DATABASE LIVE`: migration committed.
- `CLIENT DEPLOYED`: client baru aktif.
- `SMOKE PASS`: checklist authenticated lulus.
- `UAT PASS`: user menyetujui Stock, AP/Credit, PPV, AUTO RO, dan laporan.

## Emergency handling

Sebelum ada transaksi baru, kegagalan file otomatis rollback karena satu
transaction. Setelah ada Return/shortage baru, jangan drop table/function,
mengedit Posted document, atau menghapus ledger. Hentikan operasi terkait dan
buat additive forward-fix berdasarkan evidence postflight dan source document.
