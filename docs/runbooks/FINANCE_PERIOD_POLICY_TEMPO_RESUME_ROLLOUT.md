# Finance Period Policy and TEMPO Resume Rollout

Status repository: **local-ready; database rollout dan authenticated smoke menunggu user**.

## Urutan SQL

1. [`finance_period_policy_tempo_resume_preflight.sql`](../../supabase/diagnostics/finance_period_policy_tempo_resume_preflight.sql)
2. [`20260827090000_finance_period_policy_tempo_resume_fix.sql`](../../supabase/migrations/20260827090000_finance_period_policy_tempo_resume_fix.sql)
3. [`finance_period_policy_tempo_resume_postflight.sql`](../../supabase/diagnostics/finance_period_policy_tempo_resume_postflight.sql)
4. [`finance_period_policy_tempo_resume_behavioral_test.sql`](../../supabase/tests/finance_period_policy_tempo_resume_behavioral_test.sql)

Preflight dan behavioral test adalah SELECT-only. Behavioral sengaja memilih
Company dengan policy `MANUAL`, sehingga validator tidak membuat periode. Bila
fixture aman tidak tersedia, hasilnya `SETUP`, bukan error dan bukan mutation.

## Smoke manual

1. Backoffice -> Finance -> Operasi & Laporan -> Periode.
2. Ubah `Pembuatan periode` menjadi `Otomatis`; pastikan bulan berjalan dan
   bulan berikutnya tersedia. Kunci periode lama dan pastikan tidak dibuka lagi.
3. Di POS buat Draft TEMPO tanggal hari ini, simpan, buka kembali, lalu Post.
   Draft harus mempertahankan `SERVER_CREATED` dan tidak gagal hanya karena
   proses resume/reprice.
4. Buat Draft TEMPO bertanggal lampau dalam periode terbuka. Setelah dibuka
   ulang, tanggal tetap sama dan source tetap `CASHIER_SELECTED`.
5. Pilih jatuh tempo pada tanggal bisnis yang sama; perbedaan jam UTC tidak
   boleh menyebabkan `TEMPO_DUE_DATE_BEFORE_TRANSACTION`.
6. Tanggal sebelum periode terbuka tetap ditolak. Mode otomatis tidak boleh
   membuka ulang periode `LOCKED`.

## Compatibility

- Client lama tanpa `transactionDateIntent` tetap memakai perilaku lama.
- Client baru mengirim `PRESERVE` saat resume dan `CASHIER_SELECTED` hanya
  setelah kasir mengubah tanggal.
- Posting Finance tetap `CONTROLLED`; `posting_mode` belum dibuka pada UI atau
  runtime sampai fase F4.
