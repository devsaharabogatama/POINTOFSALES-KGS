# BRD-1 Company Branding Foundation Rollout

**Status:** READY FOR MANUAL DATABASE ROLLOUT  
**Migration:** `supabase/migrations/20260811110000_brd_phase1_company_branding_foundation.sql`

## Outcome

Migration ini membuat metadata logo per Company, immutable audit, guarded RPC,
RLS, optimistic versioning, dan bucket `company-branding`. Browser tidak
mendapat direct write ke metadata maupun policy write ke object bucket.

Behavioral test memakai dua Company aktif dan memastikan active-company
context benar-benar menjadi boundary: profile, resolved logo, path, mutation,
dan audit Company A tidak bocor ke Company B, begitu juga sebaliknya.

## Urutan Eksekusi

Jalankan satu file penuh per langkah di Supabase SQL Editor:

1. `supabase/migrations/20260811110000_brd_phase1_company_branding_foundation.sql`
2. `supabase/diagnostics/brd_phase1_company_branding_postflight.sql`
3. `supabase/tests/brd_phase1_company_branding_tests.sql`
4. ulangi `supabase/diagnostics/brd_phase1_company_branding_postflight.sql`

Jangan menjalankan potongan selection dan jangan membuat bucket/policy manual.

## Expected

- migration sukses tepat sekali;
- seluruh baris postflight selain `INFO` berstatus `PASS`;
- behavioral mengeluarkan notice `TEST PASSED` lalu `ROLLBACK`;
- `branding_runtime_inventory` boleh nol sebelum upload UI tersedia;
- bucket public hanya untuk read URL dokumen, tanpa authenticated write policy;
- metadata logo tidak dapat diaktifkan sebelum object server-uploaded ada;
- dua Company tetap mempunyai profile/path/audit terpisah selama behavior test.

## Batas Phase

Phase ini belum mengunggah bytes dan belum menambahkan setting UI. API server
berikutnya wajib memeriksa magic bytes, menghitung SHA-256, menghasilkan path,
upload memakai server credential, lalu memanggil RPC metadata. Service-role
tidak boleh masuk browser/log.

Test dua Company di file ini menutup tenant boundary untuk branding. Matrix
multi-Company lintas seluruh modul tetap menjadi gate PRD-1 sebelum Vercel:
switch context harus membersihkan cache, setiap list/detail/export/import wajib
tetap tenant-scoped, dan direct route/RPC lintas Company harus ditolak.

## Forward Fix

Migration applied tidak diedit atau dihapus. Jika migration gagal, kirim error
lengkap dan hentikan urutan. Jika postflight/behavior gagal setelah migration
commit, perbaikan dilakukan dengan migration baru yang version-nya lebih besar.
