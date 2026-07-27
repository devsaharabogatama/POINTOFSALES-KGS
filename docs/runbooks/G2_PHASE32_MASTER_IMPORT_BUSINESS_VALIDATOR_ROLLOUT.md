# G2 Phase 32 — Master Import Business Validator Rollout

## Status

`COMPLETE` — user mengonfirmasi migration, 7-check postflight, dan behavioral
test Supabase seluruhnya PASS.

Phase-31 identity validator sudah dikonfirmasi user seluruhnya PASS. Phase ini
menambah field business ke preview tanpa membuka commit.

## Validasi yang Ditambahkan

### Product Category

- panjang kode maksimal 50;
- panjang nama maksimal 150.

### UOM

- tipe wajib dipetakan dan hanya `UNIT`, `PACKAGING`, `WEIGHT`, `VOLUME`,
  `LENGTH`, atau `OTHER`;
- kode maksimal 30 dan nama maksimal 100;
- UOM bilangan bulat wajib precision `0`;
- UOM decimal wajib precision `1–6`.

### Warehouse

- kode 1–5 huruf kapital;
- tipe wajib dipetakan dan hanya `CENTRAL`, `STORE`, `DAMAGED`, `TRANSIT`;
- tipe `STORE` wajib menunjuk Store aktif pada Company yang sama;
- lokasi tetap opsional dan maksimal 500 karakter;
- flag sumber penjualan/tujuan pembelian divalidasi sebagai boolean;
- negative stock selalu `false`.

### Supplier

- batas panjang kode/nama serta contact, phone, address, NPWP, payment term,
  dan data bank disamakan dengan form Supplier;
- field opsional kosong dinormalisasi menjadi `NULL`.

Perubahan field business pada record existing mengubah preview `SKIP` menjadi
`UPDATE`, menambahkan before/after, dan memberi warning konfirmasi update.

## Urutan Manual

1. Jalankan migration:

   ```text
   supabase/migrations/20260723160000_g2_phase32_master_import_business_validator.sql
   ```

2. Jalankan postflight:

   ```text
   supabase/diagnostics/g2_phase32_master_import_business_validator_postflight.sql
   ```

   Expected: 7 row seluruhnya `PASS`, `violation_rows = 0`.

3. Jalankan behavioral test:

   ```text
   supabase/tests/g2_phase32_master_import_business_validator_tests.sql
   ```

   Expected notice:

   ```text
   TEST PASSED: four-master import business validation matches manual CRUD limits, isolates row errors, rejects cross-Company Store references, preserves optional Warehouse location, and remains dry-run only.
   ```

Test selalu `ROLLBACK`.

## Compatibility dan Boundary

- migration Phase 31 yang sudah applied tidak diedit;
- hook hanya memperkaya row preview sebelum summary dihitung;
- tidak ada Category/UOM/Warehouse/Supplier yang dibuat atau diubah;
- lokasi Gudang tetap tidak wajib;
- Product, Product-UOM grouped import, Brand, API/UI, export, commit, dan Opening
  Stock tetap disabled.

## Next Safe Step

Guarded partial commit empat master diteruskan pada phase 33. Product dan
Opening Stock tetap fase terpisah.
