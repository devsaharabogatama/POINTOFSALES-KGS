# Rollout Profil dan Rekening Perusahaan

## Tujuan

Menambah detail Company, tiga field rekening opsional, autofill rekening Supplier
pada Pembayaran Supplier, dan pilihan menampilkan rekening Company pada Invoice.
Rekening tidak pernah ditampilkan pada Surat Jalan.

## Urutan

1. Jalankan `supabase/migrations/20260820120000_company_profile_bank_invoice.sql`.
2. Jalankan `supabase/tests/company_profile_bank_invoice_postflight.sql`; semua baris wajib `PASS`.
3. Jalankan `supabase/tests/company_profile_bank_invoice_behavior.sql`; hasil akhir harus sukses dan transaksi di-`ROLLBACK`.
4. Deploy Backoffice dan PWA staging.
5. Buka **Platform > Profil Perusahaan**, isi tiga field rekening lengkap, lalu aktifkan **Tampilkan rekening pada Invoice**.
6. Buat Sale disposable baru. Invoice baru harus memuat rekening; Surat Jalan tidak.
7. Buka Pembayaran Supplier, pilih Supplier yang memiliki rekening, dan pastikan tiga field terisi otomatis.

## Compatibility dan data historis

- Toggle rekening Invoice default `OFF` untuk seluruh Company existing.
- Rekening Supplier pada Payment tetap menjadi snapshot yang dapat dikoreksi sebelum Draft disimpan.
- Invoice baru menyimpan rekening Company secara immutable saat Sale POSTED.
- Invoice historis tidak dibackfill karena rekening pada tanggal transaksi lama tidak dapat diasumsikan.
- Migration tidak mengubah jurnal, Stock, Payment final, atau dokumen historis.

## Forward-fix

Jika smoke gagal, nonaktifkan toggle rekening Invoice. Jangan drop kolom atau
mengubah snapshot historis. Perbaiki client/RPC melalui migration additive baru.
