# G2 Phase 40 — COA Parent UUID Aggregate Forward Fix

## Status

`COMPLETE`

## Incident

Migration `20260727090000` berhasil applied. Behavioral test kemudian berhenti
pada preview parent COA:

```text
ERROR 42883: function min(uuid) does not exist
```

Root cause hanya satu expression pada validator:

```text
min(x.id)
```

PostgreSQL tidak menyediakan aggregate `min(UUID)`.

## Fix

Migration forward-only mengganti expression runtime menjadi:

```text
min(x.id::text)::uuid
```

Tidak ada tabel, data bisnis, public RPC signature, role, grant, atau flow
import lain yang berubah. Migration Phase 40 yang sudah applied tidak diedit.

## Urutan Manual

1. Jalankan:

   `supabase/migrations/20260727100000_g2_phase40_coa_parent_uuid_aggregate_fix.sql`

2. Jalankan:

   `supabase/diagnostics/g2_phase40_coa_parent_uuid_aggregate_fix_postflight.sql`

   Expected: 4 row seluruhnya `PASS`, `violation_rows = 0`.

   Diagnostic terbaru membaca body function langsung dari `pg_proc.prosrc`
   dan tidak mengeksekusi validator atau expression parent COA.

3. Ulangi dari awal:

   `supabase/tests/g2_phase40_remaining_simple_master_import_tests.sql`

4. Setelah Phase-40 test PASS, rerun:

   `supabase/tests/g2_phase38_codeless_master_import_tests.sql`

Test fixtures sebelumnya berada dalam transaction yang gagal dan tidak
meninggalkan business/import row.

User mengonfirmasi forward migration, 4-check postflight, behavioral Phase 40,
dan regression Phase 38 seluruhnya PASS pada 2026-07-27.

## Rollback

Forward fix berjalan dalam satu transaction. Jika gagal sebelum `COMMIT`,
seluruh perubahan function/ledger rollback. Setelah applied, gunakan forward
fix baru dan jangan mengedit migration ini.
