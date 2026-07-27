# G2 Phase 40 — Remaining Simple Master Import Rollout

## Status

`COMPLETE`

## Preflight Evidence

User menjalankan Phase-40 preflight pada 2026-07-27:

- seluruh invariant berstatus `PASS`;
- tidak ada nonterminal import job;
- guarded RPC ketiga master tersedia;
- 1 Customer Category sistem, 36 COA sistem, dan 26 Transaction Category
  bawaan teridentifikasi sebagai export-only;
- tidak ada histori jurnal pada COA;
- current type constraint memang belum memuat tiga tipe baru.

## Outcome

Forward migration menambahkan generic staging, preview, dan partial commit untuk:

- Customer Category;
- Chart of Account;
- Transaction Category.

Commit selalu mendelegasikan mutation ke guarded RPC existing. Dengan demikian
audit, role, active Company, optimistic version, automatic code, COA hierarchy,
account-function compatibility, dan Finance history guard tetap sama dengan
form manual.

## Boundary

- Customer Category sistem tidak dapat diubah melalui import.
- Seluruh COA bawaan sistem tidak dapat diubah melalui generic import.
- Seluruh Transaction Category wajib bawaan tidak dapat diubah melalui import.
- COA `account_code` tetap muncul karena merupakan identitas bisnis.
- Customer/Transaction Category create template tidak meminta kode teknis.
- Parent COA harus sudah ada atau berada pada baris sebelumnya di file.
- Satu row gagal tidak me-rollback row valid lain.
- Product, Product-UOM, Pricelist, Payment Method, Customer, Product-Supplier,
  stock, Opening Stock, transaksi, dan journal tetap tidak dibuka fase ini.

## Urutan Manual

### 1. Migration

Jalankan seluruh:

`supabase/migrations/20260727090000_g2_phase40_remaining_simple_master_import.sql`

Jika gagal, transaction rollback utuh. Jangan menjalankan postflight sebelum
migration berhasil.

### 2. Postflight

Jalankan:

`supabase/diagnostics/g2_phase40_remaining_simple_master_import_postflight.sql`

Expected: tepat 10 row, seluruhnya `PASS`, `violation_rows = 0`.

### 3. Behavioral Test

Jalankan:

`supabase/tests/g2_phase40_remaining_simple_master_import_tests.sql`

Expected notice:

```text
TEST PASSED: Customer Category, COA, and Transaction Category import is tenant-safe, system-protected, versioned, audited, partial, and compatible.
```

Test selalu `ROLLBACK`.

### 4. Compatibility Regression

Rerun:

`supabase/tests/g2_phase38_codeless_master_import_tests.sql`

Ini memastikan empat import existing masih melewati wrapper compatibility.

## Rollback dan Forward Fix

- kegagalan sebelum `COMMIT` me-rollback seluruh migration;
- sesudah applied, jangan mengedit migration ini;
- gunakan migration forward-fix baru bila ditemukan masalah;
- migration Phase 30–38 tetap immutable;
- tidak ada backfill business row; constraint hanya diperluas setelah preflight
  membuktikan tidak ada job nonterminal.

Behavioral test pertama menemukan PostgreSQL `42883` pada satu expression
`min(uuid)` di parent lookup COA. Ikuti
`G2_PHASE40_COA_PARENT_UUID_AGGREGATE_FIX.md`, lalu ulangi behavioral test.

Forward fix, 4-check postflight, behavioral test Phase 40, dan regression
Phase 38 kemudian dikonfirmasi PASS oleh user pada 2026-07-27.

## Next Safe Step

Database gate sudah ditutup. Template/export/preview UI tiga tipe dilanjutkan
melalui `G2_PHASE41_REMAINING_SIMPLE_MASTER_IMPORT_UI.md`.
Grouped Product/Pricelist/Payment Method tetap gate terpisah.
