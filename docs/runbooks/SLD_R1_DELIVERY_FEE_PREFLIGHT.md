# SLD-R1 Delivery Fee Preflight

**Status:** READY TO RUN  
**Safety:** satu statement `SELECT`, aggregate-only, tanpa mutation

## Tujuan

Preflight ini memotret kesiapan database live sebelum ongkir masuk ke total
Sale dan Finance. Ia sengaja dijalankan sebelum migration R2 agar schema,
offline, Return, dan posting rule tidak dibangun dari asumsi kode lokal.

## Cara Menjalankan

Jalankan seluruh isi berikut di Supabase SQL Editor:

```text
supabase/diagnostics/sld_r1_delivery_fee_preflight.sql
```

Kirim kembali semua row `check_name,status,details`.

## Interpretasi

- `BLOCKER`: hentikan R2. Data/dependency/runtime existing harus diperbaiki dulu.
- `REVIEW`: keputusan approved harus diterapkan eksplisit. Expected saat Tax
  Sales aktif dan/atau sudah ada Return; bukan otomatis error.
- `BACKFILL`: expected untuk Sale/Invoice lama. R2 memberi ongkir nol tanpa
  mengubah histori payment, event, jurnal, atau snapshot final lama.
- `SETUP`: expected sebelum R2—kolom, runtime, account function, dan posting
  expression memang belum ada.
- `PASS`: invariant existing bersih.
- `INFO`: inventory untuk sizing migration dan regression.

## Expected Baseline

Sebelum R2, empat check umumnya belum PASS:

1. `canonical_delivery_fee_schema_state` = `SETUP`;
2. `canonical_delivery_fee_runtime_state` = `SETUP`;
3. `delivery_fee_finance_catalog_state` = `SETUP`;
4. `delivery_fee_posting_rule_state` = `SETUP`.

`legacy_delivery_fee_zero_backfill_scope=BACKFILL` juga expected bila sudah ada
Sale POSTED. Seluruh `BLOCKER` wajib nol.

## Keputusan R1 yang Dikunci

- Ongkir v1 tidak terkena pajak secara implisit. Company yang membutuhkan pajak
  ongkir harus memiliki Tax Rule eksplisit pada fase terpisah/lanjutan.
- Partial Product Return tidak otomatis mengembalikan ongkir.
- Full Return/cancellation menyediakan pilihan refund ongkir eksplisit, dengan
  approval/audit dan Finance reversal yang source-linked.
- Ongkir yang ditagih adalah pendapatan ongkir; biaya kurir aktual adalah
  Expense terpisah.

Sesudah output tanpa blocker diterima, next safe step adalah SLD-R2 migration,
postflight, dan rollback-safe behavioral test. Jangan memindahkan UI checkout
lebih dulu.
