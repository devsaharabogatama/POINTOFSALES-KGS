# G2 Phase 18 — Required Transaction Categories Rollout

## Outcome

Setiap Company memperoleh 26 kategori transaksi bawaan dengan penjelasan
user-facing. Label/keterangan dapat disesuaikan, tetapi kategori bawaan tidak
dapat dihapus, dinonaktifkan, atau dipindahkan ke jenis transaksi lain.

Migration ini tidak membuat account mapping, tidak menjalankan resolver, dan
tidak membuat jurnal.

## Urutan Manual Supabase

1. Jalankan
   `supabase/diagnostics/g2_phase18_required_transaction_categories_preflight.sql`.
2. Pastikan tidak ada status `BLOCKER`. Collision code/name harus diselesaikan
   secara eksplisit; jangan mengganti nama seed secara diam-diam.
3. Jalankan
   `supabase/migrations/20260722180000_g2_phase18_required_transaction_categories.sql`.
4. Jalankan
   `supabase/diagnostics/g2_phase18_required_transaction_categories_postflight.sql`.
5. Pastikan seluruh **11 baris** berstatus `PASS` dengan
   `violation_rows = 0`.
6. Jalankan
   `supabase/tests/g2_phase18_required_transaction_categories_tests.sql`.
7. Pastikan notice terakhir menyatakan `TEST PASSED`.
8. Restart Backoffice dan buka menu `Kategori & COA`.

## Smoke Backoffice

- daftar menampilkan 26 kategori bawaan untuk Company aktif;
- setiap baris memakai nama dan penjelasan, bukan UUID/system key;
- badge `Bawaan wajib` tampil;
- edit nama/keterangan kategori bawaan berhasil;
- jenis transaksi dan status aktif kategori bawaan tidak dapat diedit;
- kategori khusus seperti `Listrik` tetap dapat dibuat;
- tab Mapping tetap kosong sampai user menyimpan mapping;
- tidak ada jurnal atau Financial Event baru akibat rollout ini.

## Panduan User

Penjelasan setiap kategori dan contoh penggunaan berada di
`docs/FINANCE_TRANSACTION_CATEGORY_USER_GUIDE.md`.

## Forward-fix

Migration transactional. Bila gagal sebelum `COMMIT`, seluruh perubahan
rollback. Setelah ledger `20260722180000` ada, jangan edit migration ini;
gunakan forward migration. Finance posting tetap disabled.
