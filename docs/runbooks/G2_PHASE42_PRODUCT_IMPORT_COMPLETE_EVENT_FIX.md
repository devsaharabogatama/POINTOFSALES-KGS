# G2 Phase 42 — Product Import COMPLETE Event Forward Fix

**Status:** `COMPLETE` — migration, 4-check postflight, Phase-42 behavior, dan
regression Phase 40/38 dikonfirmasi user seluruhnya PASS.

## Root cause

Behavioral test Phase 42 mencapai commit Product group, lalu gagal saat menulis
audit event:

```text
master_import_job_events_type_check
event_type = COMMIT
```

Vocabulary canonical tabel tersebut adalah `COMPLETE`. Seluruh behavioral test
berada dalam satu transaction dan berakhir error, sehingga fixture, Product,
Product-UOM, job, serta audit test rollback seluruhnya.

Migration Phase 42 sudah applied dan tidak boleh diedit.

## File

1. Forward migration:
   `supabase/migrations/20260727140000_g2_phase42_product_import_complete_event_fix.sql`
2. Postflight:
   `supabase/diagnostics/g2_phase42_product_import_complete_event_fix_postflight.sql`
3. Regression utama:
   `supabase/tests/g2_phase42_grouped_product_import_tests.sql`

## Urutan

1. Jalankan forward migration `20260727140000`.
2. Jalankan postflight; expected **4 PASS**.
3. Jalankan ulang behavioral test Phase 42; expected notice `TEST PASSED`.
4. Jalankan regression Phase 40 dan Phase 38.

Tidak perlu menjalankan ulang migration `20260727130000` dan tidak perlu
membersihkan fixture secara manual.

## Scope

Perubahan hanya mengganti audit literal `COMMIT` menjadi `COMPLETE` pada private
Product import commit routine. Signature public/private, Product write,
partial-commit behavior, optimistic version, dan stock boundary tidak berubah.
