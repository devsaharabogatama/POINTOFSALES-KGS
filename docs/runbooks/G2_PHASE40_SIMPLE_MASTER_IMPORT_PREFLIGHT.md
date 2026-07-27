# G2 Phase 40 — Remaining Simple Master Import Preflight

## Status

`COMPLETE`

## Tujuan

Mengaudit kesiapan perluasan Import/Export ke tiga master sederhana berikut:

- Customer Category;
- Chart of Account (COA);
- Transaction Category.

Fase ini masih `SELECT-only`. Belum ada tipe job baru, validator, commit, atau
perubahan UI.

## Kontrak yang Dipertahankan

- Customer Category dan Transaction Category tidak meminta kode teknis pada
  template create; kode dibuat server-side.
- Kategori sistem (`GENERAL`) dan 26 Transaction Category bawaan bersifat
  export-only dan tidak boleh dimutasi generic import.
- COA tetap meminta `account_code` karena merupakan identitas bisnis yang
  dipakai dalam laporan, rekonsiliasi, audit, dan integrasi akuntansi.
- UUID hanya tersedia pada export update untuk mode pencocokan ID.
- Referensi parent COA dan System Event harus diselesaikan tenant-safe; missing
  atau ambiguous reference menjadi row error dan tidak auto-create.
- Update COA yang sudah memiliki histori jurnal tetap tunduk pada history guard
  existing.
- Import tidak mengaktifkan journal posting, checkout, stock, atau Opening
  Stock.

## Cara Menjalankan

Jalankan seluruh file berikut di Supabase SQL Editor:

`supabase/diagnostics/g2_phase40_simple_master_import_preflight.sql`

Kirim seluruh hasil `check_name,status,details`.

## Expected Result

- Semua baris invariant berstatus `PASS`.
- Baris `INFO` hanya inventory/current-state.
- `remaining_import_type_contract` diperkirakan menunjukkan ketiga tipe masih
  `false`; itu expected karena migration Phase 40 belum ditulis.
- `nonterminal_import_jobs` harus `PASS` sebelum constraint dan validator job
  diperluas.

Jika ada `BLOCKER`, jangan jalankan migration lanjutan. Hasil tersebut harus
direview untuk menentukan backfill atau forward-fix eksplisit.

## Live Result

User mengirim hasil pada 2026-07-27:

- seluruh invariant `PASS`;
- tidak ada duplicate, blank identity, hierarchy issue, invalid System Event,
  atau nonterminal job;
- ketiga guarded RPC tersedia;
- 1 Customer Category sistem, 36 COA sistem, dan 26 required Transaction
  Category menjadi export-only;
- satu custom Transaction Category tetap dapat dikelola;
- current job constraint belum mendukung tiga tipe baru, sesuai expected state.

## Next Safe Step

Preflight sudah bersih. Lanjutkan rollout menurut
`G2_PHASE40_REMAINING_SIMPLE_MASTER_IMPORT_ROLLOUT.md`, yang:

1. memperluas tipe job secara additive;
2. menambahkan validator dan partial commit untuk tiga master;
3. memakai guarded RPC existing, optimistic `master_version`, audit, serta
   per-row subtransaction;
4. menolak mutation kategori sistem/default;
5. menyediakan postflight dan behavioral test sebelum UI ditambah.
