# Rollout Pengaturan Tanggal Invoice

## Tujuan

Owner/Admin Company dapat memilih tanggal yang dicetak pada Invoice final:

- `ORDER_DATE`: tanggal bisnis/order yang dipilih saat membuat transaksi, termasuk backorder;
- `POSTED_DATE`: tanggal transaksi benar-benar diposting.

Output print/PDF hanya menampilkan tanggal dalam timezone Company, tanpa jam.
Pilihan disimpan per Company dan disnapshot ke Invoice baru. Invoice lama tetap
memakai fallback `ORDER_DATE`, sehingga histori tidak ditulis ulang.

## Urutan manual Supabase

1. Jalankan `supabase/diagnostics/invoice_date_display_policy_preflight.sql`.
2. Pastikan tidak ada `BLOCKER`.
3. Jalankan `supabase/migrations/20260827150000_invoice_date_display_policy.sql`.
4. Jalankan `supabase/tests/invoice_date_display_policy_postflight.sql`.
5. Jalankan `supabase/tests/invoice_date_display_policy_behavior.sql`.
6. Jalankan postflight sekali lagi; seluruh check wajib `PASS`.

## Smoke browser

1. Masuk sebagai Owner/Admin dan buka `Platform -> Profil Perusahaan`.
2. Pilih `Tanggal Order`, buat Sale dengan tanggal order lampau, lalu POST.
3. Buka/unduh Invoice dari POS dan Backoffice. Tanggal harus sama dengan tanggal
   order, tanpa jam.
4. Ubah setting menjadi `Tanggal Transaksi`, buat Sale baru dengan tanggal order
   lampau, lalu POST. Invoice baru harus memakai tanggal POST hari ini.
5. Cetak ulang Invoice pada langkah 2. Tanggalnya wajib tetap tanggal order.
6. Pastikan Surat Jalan tidak berubah.

## Compatibility dan rollback

- Default `ORDER_DATE` mempertahankan perilaku Backoffice yang sudah berjalan.
- Signature RPC empat parameter dipertahankan sebagai wrapper compatibility;
  client baru memakai signature lima parameter.
- Rollback schema tidak dianjurkan setelah Invoice baru tercipta. Forward-fix
  aman adalah mengembalikan policy Company ke `ORDER_DATE`; snapshot final tidak
  boleh dimutasi.
