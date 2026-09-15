# Backoffice Sales — Accepted Overage Invoice Runtime (Step 4/6.5C2B)

Status: **DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS ON ISOLATED DEVELOPMENT**.

Target hanya project isolated Development `fkywtxucmyjvpwdiqpix`. Agent tidak
menjalankan SQL ini dan tidak menyentuh production/staging.

## Historical clone rehearsal evidence — 2026-09-15

- Clone `idrufihckscppsyclmsu` only: unit 61 installed; preflight six PASS,
  initial/closing postflight six PASS each; rollback-only behavior PASS with
  11 reported scenarios including Draft/Edit/Cancel, exact retry, two partial
  postings, separate SO counters and final discount remainder.
- Test preparation now selects Auth-backed actor and sets Office mode under
  Company lock, clearing setup marker before asserting root creation guard/RPC.
  No runtime guard bypass, installed migration edit or Production/client change.
- Synthetic resolved source and COMPLETED SO prove Invoice runtime, NOT physical
  Dispatch/receipt/resolution. Applied-tax, cross-tenant, stale-version and
  concurrency cases are not proven by this fixture. UI smoke/UAT still pending.
- Stopped before unit 62: its fixture lacks Office-mode preparation; audit
  blocker only, no unit 62 SQL executed. Progress 61/88 installed.

## Outcome

- Accepted overage yang sudah `APPROVED + RESOLVED` dapat menjadi line Product
  Invoice terpisah berlabel `Kelebihan barang`.
- Partial Invoice diizinkan. Diskon approval dialokasikan proporsional terhadap
  quantity; Invoice terakhir mengambil sisa pembulatan.
- Pajak dihitung per Invoice dari nilai setelah diskon menggunakan immutable
  tax snapshot approval; Invoice terakhir mengambil sisa pembulatan pajak.
- Draft/Edit/Cancel/Post dan exact retry menjaga counter discrepancy terpisah
  dari counter quantity SO.
- Paket tidak membuat UI resolver Gudang, tidak mengubah Stock/FIFO/Dispatch,
  tidak mengubah POS Retail, dan tidak mengganti Finance mapping.

## Impact map

- Direct: wrapper/core Draft Invoice, Cancel Draft, Post Invoice, allocation
  validator/counter, dan Invoice line lineage.
- Downstream: total Invoice, tax breakdown, receivable schedule, Financial Event,
  serta Journal memakai total canonical yang sudah memasukkan overage.
- Compatibility: allocation lama tetap `SALES_ORDER`; counter SO hanya diproses
  untuk source tersebut. Source `ACCEPTED_OVERAGE` memakai counter discrepancy.
- Concurrency/retry: lock Invoice/SO existing tetap dipakai, discrepancy source
  dikunci sebelum hold, operation identity existing tetap authoritative.
- Rollback: setelah migration applied gunakan forward-fix additive; jangan edit
  migration yang sudah dijalankan. Jika migration gagal sebelum `COMMIT`, seluruh
  perubahan transaksi rollback.

## Urutan manual

1. Jalankan [preflight](../../supabase/diagnostics/backoffice_sales_accepted_overage_invoice_runtime_preflight.sql) secara utuh.
2. Stop bila ada `BLOCKER`, `FAIL`, atau SQL error.
3. Jalankan [migration](../../supabase/migrations/20260912124000_backoffice_sales_accepted_overage_invoice_runtime.sql).
4. Jalankan [postflight](../../supabase/diagnostics/backoffice_sales_accepted_overage_invoice_runtime_postflight.sql).
5. Jalankan [behavioral test](../../supabase/tests/backoffice_sales_accepted_overage_invoice_runtime_behavior.sql) secara utuh. Test memakai transaksi rollback-only.
6. Jalankan postflight sekali lagi.
7. Kirim seluruh result set. Jangan lanjut ke client/UI atau resolver final bila
   ada selain `PASS/INFO`.

## Manual smoke setelah seluruh SQL PASS

Belum dilakukan pada gate ini. Smoke berikutnya harus memakai UI authenticated
setelah read-model/client C2C tersedia: resolved accepted overage → dua partial
Invoice → cancel/edit Draft → Post → total discount/tax/quantity reconcile.
