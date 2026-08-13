# ACP-1 Access Compatibility Preflight

**Status:** READY TO RUN  
**Safety:** SELECT-only; aggregate metadata; tidak menampilkan user/email/data
bisnis dan tidak mengubah runtime.

## Tujuan

Membuktikan role baseline existing aman sebelum custom restriction schema dibuat.
Preflight mengaudit membership, active Company context, Store scope, role UAT,
regular multi-Company identity, RLS semua table tenant, direct browser write
pada Stock/Finance/membership, helper role, dan expected absence custom schema.

Code-derived navigation/action snapshot berada di
`../ACP1_ACCESS_ACTION_BASELINE_MATRIX.md`.

## Cara Menjalankan

Jalankan seluruh file berikut sebagai satu query di Supabase SQL Editor:

`supabase/diagnostics/acp_phase1_access_compatibility_preflight.sql`

Kirim seluruh output tanpa menghapus row `REVIEW`, `SETUP`, atau `INFO`.

## Interpretasi

- `BLOCKER`: jangan lanjut ACP-2; fondasi role/tenant/RLS existing perlu
  corrective review terlebih dahulu.
- `REVIEW`: bukan otomatis error. Cocokkan direct-write/Store-role divergence
  dengan execution path dan matrix.
- `SETUP`: fixture UAT atau custom schema memang belum tersedia. Khusus
  `custom_permission_schema_state`, `SETUP` adalah hasil yang diharapkan.
- `PASS`: invariant tersebut aman pada saat query berjalan.
- `INFO`: fingerprint untuk membandingkan shadow resolver ACP-2.

## Expected Sebelum ACP-2

1. semua `BLOCKER` bernilai nol;
2. `custom_permission_schema_state=SETUP` dengan tiga relation missing;
3. role/multi-Company `SETUP` boleh tetap ada hanya bila akun UAT belum lengkap;
4. `company_scoped_authenticated_write_inventory=REVIEW` wajib dibandingkan
   dengan guarded master workflow; jangan mencabut privilege massal dari hasil
   count saja;
5. tidak menjalankan migration atau membuat override setelah query ini. Agent
   harus membekukan action split final lebih dahulu.

## Tidak Dilakukan Fase Ini

- tidak membuat role baru atau multi-role satu Company;
- tidak membuat permission table/resolver;
- tidak mengubah navigation/API/RPC/RLS;
- tidak mengaktifkan feature;
- tidak membuat user, Company, Store, atau Warehouse;
- tidak membuka Vercel Preview.

## Next Safe Step

Kirim output lengkap. Jika bersih, finalisasi catalog/action split dan baru
siapkan ACP-2 shadow-mode database foundation dengan no-override parity.
