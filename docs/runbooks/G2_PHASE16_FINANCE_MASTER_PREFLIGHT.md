# G2 Phase 16 — Transaction Category dan Minimum COA Preflight

## Tujuan

Mengaudit kesiapan live database sebelum membangun master Transaction Category,
Account Function, dan minimum Chart of Accounts (COA). Audit menggabungkan
keduanya karena mapping kategori wajib menunjuk Account ID yang tenant-safe.

Audit ini tidak mengubah schema/data dan tidak mengaktifkan Finance worker,
automatic journal, resolver, accounting period, atau production posting.

Source of truth:

- `docs/TRANSACTION_CATEGORY_ACCOUNT_MAPPING_SPEC.md`;
- `docs/FINANCE_CORE_ACCOUNTING_SPEC.md` bagian COA dan resolusi akun;
- G2 pada `docs/POS_V1_IMPLEMENTATION_GATES.md`;
- gap `B-06` pada `docs/PRE_BUILD_IMPLEMENTATION_GAP_AUDIT_2026-07-20.md`.

## Cara menjalankan

1. Buka Supabase SQL Editor.
2. Jalankan seluruh isi
   `supabase/diagnostics/g2_phase16_finance_master_preflight.sql`.
3. Kirim seluruh hasil `check_name,status,details`.

File bersifat `SELECT-only` dan aman dijalankan pada database live.

## Interpretasi

- `BLOCKER`: data ledger lama melanggar invariant dan harus diselesaikan sebelum
  migration ditulis.
- `REVIEW`: identitas Category/COA lama bertabrakan setelah normalisasi; perlu
  keputusan mapping eksplisit, bukan auto-merge.
- `BACKFILL`: expected untuk Company aktif yang perlu template COA dan untuk
  kategori Expense lama yang perlu master canonical.
- `INFO`: inventory/schema gap, bukan kegagalan.
- `PASS`: invariant yang diaudit bersih.

Pada database tanpa histori Finance, hasil normal adalah dependency `PASS`,
Company aktif masuk `BACKFILL`, schema canonical/snapshot masih `INFO`, dan
seluruh invariant legacy `PASS`.

## Boundary fase berikutnya

Hasil preflight hanya boleh dipakai untuk menyiapkan fondasi additive:

- registry System Event dan Account Function yang system-owned;
- minimum COA per Company dengan Account ID stabil;
- Transaction Category tenant-scoped;
- versioned account-function mapping serta explicit fallback;
- nullable snapshot/link pada event dan journal lama;
- missing-mapping queue tanpa menjalankan posting production.

Worker lama tidak boleh dipatch dengan kode COA baru satu per satu. Enforcement,
period lock, automatic posting, retry resolver, dan reconciliation tetap berada
pada gate Finance setelah taxonomy, backfill, serta test matrix lengkap lulus.
