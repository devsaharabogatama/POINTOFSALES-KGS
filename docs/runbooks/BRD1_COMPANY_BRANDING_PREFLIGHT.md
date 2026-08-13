# BRD-1 Company Branding Preflight

**Status:** READY TO RUN  
**SQL:** `supabase/diagnostics/brd_phase1_company_branding_preflight.sql`

## Tujuan

Memastikan schema Company, role operator, Supabase Storage, bucket/policy, dan
browser write boundary aman sebelum migration branding dibuat. SQL SELECT-only.

## Cara Menjalankan

1. Buka Supabase SQL Editor.
2. Jalankan seluruh file preflight sekali.
3. Kirim hasil `check_name,status,details` lengkap.

## Expected Baseline

- dependency dan Storage catalog: `PASS`;
- schema/profile/audit/bucket: `SETUP` karena migration belum dibuat;
- existing branding object dan unsafe policy: `PASS`;
- Company identity: `PASS`;
- operator readiness boleh `REVIEW` bila Company belum punya Owner/Admin;
- inventory metadata: `INFO`.

`SETUP` bukan error. `BLOCKER` wajib ditutup sebelum migration. Jangan membuat
bucket manual agar policy/limit/MIME tidak berbeda dari source control.

Setelah aman, migration target `20260811110000` menambahkan profile/audit,
guarded RPC, RLS/grant, bucket contract, postflight, dan behavioral test.
