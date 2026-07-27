# G2 Phase 38 — Code-less Simple Master Import Rollout

## Status

`COMPLETE`

## Outcome

Memindahkan template create CSV untuk Product Category, UOM, Warehouse, dan
Supplier dari kode teknis yang diketik user menjadi nama + field bisnis.
Validator menyiapkan kode teknis secara server-side dalam transaction preview,
dan commit existing memakai identitas yang sama.

Phase ini belum menambah jenis import baru. Ini adalah compatibility gate wajib
sebelum full Master Import diperluas ke master sederhana dan grup atomik.

## Files

1. Migration:
   `supabase/migrations/20260724040000_g2_phase38_codeless_master_import.sql`
2. Postflight:
   `supabase/diagnostics/g2_phase38_codeless_master_import_postflight.sql`
3. Behavioral test:
   `supabase/tests/g2_phase38_codeless_master_import_tests.sql`

## Rollout Order

Jalankan satu per satu di Supabase SQL Editor:

1. seluruh migration;
2. seluruh postflight;
3. seluruh behavioral test.

Expected:

- migration sukses satu kali;
- 7 postflight row seluruhnya `PASS`, `violation_rows = 0`;
- behavioral test menghasilkan notice:
  `TEST PASSED: code-less templates allocate stable server codes...`;
- seluruh fixture, job, event, master, audit, dan counter allocation rollback.

Kirim output postflight lengkap dan notice behavioral test sebelum Backoffice
template dipindahkan ke format tanpa kode.

User mengonfirmasi migration, seluruh 7 postflight check, dan behavioral test
aman pada 2026-07-24. Backoffice code-less cutover dilanjutkan pada Phase 39.

## Compatibility

- validator Phase 31 dipertahankan sebagai private implementation;
- signature public `validate_master_import_job(uuid,bigint)` tidak berubah;
- CSV lama yang memetakan `code` tetap memakai version flow lama;
- CSV baru boleh hanya memetakan `name` dan field bisnis;
- update berdasarkan nama/ID memakai ulang kode immutable existing;
- kode baru disiapkan server-side dan stabil dari preview sampai commit;
- Warehouse menerima kode lama 1–5 huruf dan format baru `WH-000001`;
- commit, update confirmation, partial success, optimistic version, audit, dan
  retry idempotency Phase 33 tidak diubah;
- Product SKU, Customer code, COA, Tax, barcode, dan vendor Product code tidak
  berubah.

## Failure and Concurrency

Persiapan kode dan validator lama berjalan dalam satu transaction. Bila
validator melempar exception, perubahan mapping, staged synthetic code, dan
counter ikut rollback. Baris invalid yang selesai sebagai preview error dapat
menyisakan gap nomor; gap diperbolehkan dan kode tidak boleh digunakan ulang.

Commit tetap memakai advisory lock per Company/import type, matched master
version, unique constraint, dan per-row error isolation dari Phase 33.

## Rollback / Forward-fix

Migration satu transaction. Error sebelum `COMMIT` mengembalikan validator ke
schema/signature semula dan tidak menulis ledger. Setelah applied:

- jangan edit atau rerun migration;
- jangan menghapus private validator compatibility;
- buat forward migration bila ditemukan regression;
- jangan menurunkan counter atau menggunakan ulang kode.

## Deferred

- Backoffice template/create mapping tanpa kode menunggu database gate PASS;
- Customer Category, Customer, Product group, Product-Supplier, Pricelist,
  Payment Method, Tax, COA, Transaction Category, dan finance mapping masuk
  gate full-import berikutnya;
- Product/Pricelist/Payment Method harus atomic per group;
- Opening Stock tetap G3;
- Company, Staff/password, entitlement, transaksi, movement, dan journal tidak
  masuk generic import.
