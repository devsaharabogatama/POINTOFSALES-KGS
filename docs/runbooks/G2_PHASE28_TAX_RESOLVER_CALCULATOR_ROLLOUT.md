# G2 Phase 28 — Private Tax Resolver/Calculator Rollout

## Status

`COMPLETE` — user mengonfirmasi migration, 7-check postflight, dan behavioral
test seluruhnya PASS. Transaction cutover tetap disabled.

Live preflight diterima bersih:

- seluruh invariant `PASS`;
- dua scope Tax aktif pada satu Company;
- satu Product menghasilkan dua scope `no tax` karena belum ada assignment;
- belum ada Tax Rule/current version maupun transaction history;
- checkout legacy tidak mereferensikan snapshot Tax;
- direct update Sales/Purchase detail tetap tertutup.

## Perubahan

Migration `20260723070000` menambahkan dua routine server-only:

1. `private.resolve_product_tax_rule(...)`
   - mengecek entitlement pada timestamp posting eksplisit;
   - prioritas `Product override → Category default → no tax`;
   - rule harus satu, aktif, effective, sesuai scope, serta memakai akun aktif
     dan postable;
   - Sales wajib `INCLUSIVE`;
   - mengembalikan snapshot rule/account siap dipakai transaction writer masa
     depan.
2. `private.calculate_tax_group(...)`
   - pure deterministic calculator;
   - mendukung Sales inclusive serta Purchase inclusive/exclusive;
   - `PER_LINE` membulatkan setiap line ke precision IDR;
   - `PER_DOCUMENT` membulatkan sekali pada group dan menempelkan residual ke
     line dengan tax base terbesar; tie memakai urutan input pertama;
   - Tax rounding terpisah dari grand-total rounding POS Rp100.

Tidak ada public RPC baru. `anon` dan `authenticated` tidak dapat mengeksekusi
routine; `service_role` dapat memakainya dari transaction writer server-side di
fase berikutnya.

## Urutan Manual Wajib

Jalankan file secara berurutan di Supabase SQL Editor.

### 1. Migration

```text
supabase/migrations/20260723070000_g2_phase28_tax_resolver_calculator.sql
```

Expected: sukses satu transaction.

### 2. Postflight

```text
supabase/diagnostics/g2_phase28_tax_resolver_calculator_postflight.sql
```

Expected: 7 row, seluruhnya `PASS` dan `violation_rows = 0`.

Khusus `checkout_tax_cutover_remains_disabled`, expected
`tax_integrated_routines = 0`.

### 3. Behavioral test

```text
supabase/tests/g2_phase28_tax_resolver_calculator_tests.sql
```

Expected notice:

```text
TEST PASSED: Tax resolution is tenant/scope/effective-safe and PER_LINE/PER_DOCUMENT calculation is deterministic; transaction cutover remains disabled.
```

Seluruh fixture diakhiri `ROLLBACK`.

## Compatibility

- tidak mengubah tabel atau row bisnis existing;
- tidak mengubah assignment Product/Category;
- tidak mengubah Tax Rule existing;
- tidak menulis snapshot Sales/Purchase;
- tidak mengubah Backoffice/PWA;
- checkout, Supplier Invoice Tax, Finance posting, return/reversal, dan official
  tax reporting tetap disabled.

## Forward Fix

Jangan edit migration setelah applied. Koreksi resolver/calculator memakai
`CREATE OR REPLACE FUNCTION` pada migration dengan version lebih tinggi dan
wajib mengulang behavioral regression.

## Next Safe Step

Setelah database gate PASS, audit kontrak transaction writer yang akan
menempelkan resolver + calculator snapshot secara atomic. Jangan langsung
mengubah checkout lama sebelum idempotency, pricing stack, discount, rounding,
payment total, stock/FIFO, dan journal boundary G3/G4 siap.
