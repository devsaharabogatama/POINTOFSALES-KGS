# Evidence G2 Fase 2 - Canonical Master API

**Tanggal konfirmasi:** 2026-07-21
**Status:** COMPLETE

## Evidence

- API Category, UOM, dan Warehouse menggunakan bearer session caller.
- Active Company dibaca server-side dan `company_id` tidak diterima dari body.
- Mutation berjalan melalui caller Supabase client dan RLS tanpa service-role.
- PATCH memakai optimistic concurrency berdasarkan `master_version`.
- Backoffice lint dan production build berhasil.
- Local authenticated API smoke dikonfirmasi tidak memiliki masalah.

## Keputusan Lanjutan

Backend master ditutup untuk scope awal. Tahap berikutnya menyambungkan frontend
Backoffice untuk list/create/edit/archive Category, UOM, dan Warehouse. Product
serta Product-UOM form tetap menunggu ketiga reference master dapat dikelola.
