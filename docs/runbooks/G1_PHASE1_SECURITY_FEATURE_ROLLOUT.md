# Runbook G1 Fase 1 — Security dan Feature Entitlement

**Migration:** `supabase/migrations/20260720090000_g1_phase1_security_feature_foundation.sql`  
**Requirement:** TEN-001, TEN-002, TEN-003  
**Status:** SIAP DIREVIEW; belum dianggap applied sampai postflight production disimpan

## Scope

Migration ini:

- menjadikan delapan `company_id` inventory yang sudah bersih sebagai `NOT NULL`;
- membuat katalog feature, entitlement per Company, dan audit perubahan;
- memastikan toggle feature hanya melalui Super Admin;
- membuat ledger migration milik aplikasi untuk deployment lewat SQL Editor;
- mencabut privilege `anon`, `TRUNCATE`, `REFERENCES`, `TRIGGER`, dan RPC legacy yang tidak aman;
- memperbaiki `search_path` worker Finance dan transfer legacy tanpa mengubah body function.

Migration ini belum menyelesaikan seluruh G1. Composite tenant FK, active Company context, dan matrix role/action penuh masuk migration berikutnya setelah hasil fase ini diverifikasi.

## Preflight Manual

1. Pastikan project/branch Supabase sama dengan project hasil G0.
2. Simpan export fingerprint G0 di lokasi audit internal.
3. Pastikan tidak ada deployment/schema change lain yang sedang berjalan.
4. Jalankan ulang `supabase/diagnostics/g0_schema_baseline.sql` bila database berubah sejak 2026-07-20. Hentikan rollout jika ada `FAIL` atau salah satu delapan tabel memiliki `company_id` NULL.
5. Ambil backup/snapshot sesuai fasilitas plan yang tersedia. Jika tidak tersedia, minimal export schema serta data table yang disentuh.
6. Buka migration dan pastikan versi `20260720090000` belum ada di `private.kgs_schema_migrations`.

## Eksekusi

1. Salin seluruh isi migration ke Supabase SQL Editor.
2. Jalankan sebagai satu batch. Script memakai transaction; error akan membatalkan seluruh perubahan.
3. Jangan menjalankan ulang jika hasil pertama sukses. Guard akan menghasilkan `MIGRATION_ALREADY_APPLIED`.
4. Jalankan seluruh isi `supabase/diagnostics/g1_phase1_postflight.sql`.
5. Export hasil postflight. Semua baris wajib `PASS`.
6. Jalankan `supabase/diagnostics/g1_phase1_behavior_preflight.sql`. Minimal satu `super_admin_profiles_linked_to_auth` wajib tersedia. User normal dan Company tidak wajib karena test memakai fixture rollback-only.
7. Jalankan `supabase/tests/g1_phase1_feature_entitlement_tests.sql`. Script selalu `ROLLBACK` dan harus menghasilkan notice `TEST PASSED`.

## Smoke Test Manual

1. Login user normal: katalog feature Company sendiri dapat dibaca, tetapi mutation langsung ditolak.
2. Login Company Admin: tidak dapat memanggil `set_company_feature`.
3. Login Super Admin: panggil `set_company_feature` pada Company test, lalu pastikan row audit terbentuk.
4. Kembalikan feature test ke disabled; jangan mengaktifkan feature bisnis yang implementasinya belum selesai.
5. Login normal dan buka halaman existing Product/POS yang tersedia untuk memastikan SELECT/API lama tidak terganggu.
6. Jalankan worker Finance melalui route server yang memakai service role; direct RPC dari browser/authenticated harus ditolak.

Contoh toggle hanya untuk pengujian Super Admin:

```sql
-- Jalankan melalui client/API ber-session Super Admin, bukan SQL Editor tanpa JWT.
select public.set_company_feature(
  '<company-uuid>'::uuid,
  'tax_sales_enabled',
  false,
  '{}'::jsonb
);
```

## Stop dan Forward Fix

- Jika migration gagal: simpan error lengkap dan jangan menjalankan potongan SQL secara terpisah.
- Jika postflight gagal: jangan lanjut G1 fase 2.
- Jika flow lama kehilangan privilege yang benar-benar dibutuhkan, identifikasi exact role, object, dan action. Buat forward migration dengan grant minimum.
- Jangan mengembalikan `GRANT ALL`, `EXECUTE TO PUBLIC`, atau privilege `TRUNCATE` kepada role browser.
- Jangan drop feature/audit table setelah audit mulai berisi histori.

## Evidence yang Harus Disimpan

- waktu dan target branch execution;
- hasil migration sukses/error;
- export postflight;
- hasil smoke test empat role;
- ID/commit source migration yang dijalankan;
- catatan forward fix bila ada.
