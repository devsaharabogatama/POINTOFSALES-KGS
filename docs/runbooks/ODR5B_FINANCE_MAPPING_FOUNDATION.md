# ODR-5B Finance Mapping Foundation

Tahap ini membuat konfigurasi Finance yang diperlukan oleh Dispatch dan
verifikasi pembayaran ODR. Ia tidak membuat Financial Event atau Journal dan
tidak menjalankan posting queue.

## Urutan manual

1. Pastikan output
   `odr_phase5b_reusable_account_mapping_preflight.sql` hanya menyisakan
   `customer_advance_provision_scope = BACKFILL`; seluruh check lain harus
   `PASS`/`INFO`.
2. Jalankan
   `supabase/migrations/20260828220000_odr_phase5b_finance_mapping_foundation.sql`.
3. Jalankan
   `supabase/diagnostics/odr_phase5b_finance_mapping_foundation_postflight.sql`.
   Semua check selain inventory wajib `PASS`.
4. Jalankan
   `supabase/tests/odr_phase5b_finance_mapping_foundation_behavioral_test.sql`.
   Hasil harus `PASS`; seluruh test di-rollback.
5. Jalankan ulang postflight. Hasil wajib tetap sama.

## Efek yang memang diharapkan

- satu akun sistem `2190 - Uang Muka Customer` per Company aktif;
- dua Transaction Category ODR per Company;
- 17 exact Account Function mapping per Company;
- dua approved versioned Posting Rule Set per Company dengan total 18 line;
- audit master/rule set append-only.

## Batas keselamatan

- migration berhenti bila Finance queue atau Offline submission aktif;
- migration berhenti bila source ODR sudah berisi data;
- collision kode/nama akun dan kategori ditolak;
- akun existing dipilih dari exact source-event rule, Company fallback, atau
  satu system-owned account; kandidat ganda ditolak;
- `BANK_RECEIPT` mengikuti mapping bank yang sudah dipakai kontrak Finance
  Sale/Return;
- tidak ada event, jurnal, stok, FIFO, pembayaran, invoice, atau delivery yang
  dimutasi.

Setelah closing postflight bersih, langkah aman berikutnya adalah runtime source
capture dan dispatcher ODR-5C. Jangan menyalakan automatic posting pada tahap
ini.
