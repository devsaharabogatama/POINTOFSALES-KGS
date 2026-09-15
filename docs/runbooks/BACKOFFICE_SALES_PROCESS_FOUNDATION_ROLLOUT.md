# Backoffice Sales Process Identity Foundation

**Status:** DEVELOPMENT DATABASE PASS / BEHAVIORAL FIXTURE PENDING / FEATURE OFF

## Perubahan

- catalog feature `backoffice_delivered_qty_sales_enabled` tanpa entitlement
  Company;
- `sales_headers.sales_origin`, default `POS`;
- `sales_headers.sales_process_mode`, default `RETAIL_CONFIRM_INVOICE`;
- constraint pasangan source/mode dan trigger immutable;
- server menolak row Backoffice bila entitlement Company belum aktif.

Tidak ada perubahan pada POS RPC, Invoice/SJ, Reservation, Stock/FIFO/Movement,
Payment, Finance, client, atau data final. Constraint satu Invoice dan satu DO
per Sale sengaja dipertahankan pada foundation ini.

## Urutan manual

1. `backoffice_sales_process_foundation_preflight.sql`
2. `20260908100000_backoffice_sales_process_identity_foundation.sql`
3. `backoffice_sales_process_foundation_postflight.sql`
4. `backoffice_sales_process_foundation_test.sql`
5. ulangi postflight

Hentikan bila ada `BLOCKER`. Test membutuhkan minimal satu Sale existing dan
seluruh percobaan mutation dibungkus transaction yang di-rollback.

## Forward-fix / rollback

Feature belum diaktifkan pada Company mana pun, sehingga forward-fix adalah
pilihan utama. Sebelum ada row Backoffice, rollback terkontrol dapat menghapus
trigger/function, dua constraint/kolom, catalog feature, lalu ledger entry.
Jangan rollback setelah feature pernah enabled atau row Backoffice ada.

## Status yang tidak boleh diklaim dari file ini

- multiple Invoice/DO belum tersedia;
- Quotation/SO Backoffice belum tersedia;
- belum `DATABASE LIVE`, `CLIENT DEPLOYED`, `SMOKE PASS`, atau `UAT PASS`.

## Development evidence 2026-09-08

- Target: isolated Development `fkywtxucmyjvpwdiqpix`; production dan staging
  lama tidak disentuh.
- Full baseline ledger sinkron sampai `20260908100000`.
- Preflight foundation PASS dan postflight seluruh contract schema PASS.
- Feature catalog tersedia tetapi enabled Company tetap 0.
- Syntax CHECK pair diperbaiki sebelum migration berhasil diterapkan; migration
  yang gagal sebelumnya tidak meninggalkan perubahan parsial.
- Behavioral mutation test belum dijalankan karena Sales fixture masih 0. Ini
  bukan behavioral PASS dan menunggu fixture Development yang representatif.
