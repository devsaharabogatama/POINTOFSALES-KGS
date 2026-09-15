# Backoffice Sales Delivery Fee Parity Rollout

## Status dan boundary

- Current gate: **STEP 1E-B1/6 — DATABASE LIVE + POSTFLIGHT/BEHAVIOR USER-CONFIRMED PASS**.
- Target hanya isolated Supabase Development `fkywtxucmyjvpwdiqpix`.
- Agent tidak menjalankan SQL ke database dan tidak mengubah production/staging.
- POS Retail, Reservation, DO/Transit, Stock/FIFO/COGS, Payment, dan transaksi
  historis tidak dimutasi oleh gate ini.

Gate ini menutup gap nilai antara source Retail dan target Backoffice sebelum
converter cutover Step 1E-B2 ditulis. Quotation/SO Backoffice memperoleh ongkir
header; DP tidak boleh membawa ongkir; Regular Invoice pertama otomatis mengisi
sisa ongkir SO dan Finance mempostingnya terpisah ke account function canonical
`DELIVERY_FEE_REVENUE`.

Migration `20260910150000` sudah dijalankan user pada isolated Development.
Behavioral pertama membuktikan wrapper Draft Invoice mencoba memperbarui
`backoffice_sales_invoice_audit` setelah core canonical menulis audit immutable,
sehingga berhenti pada `BACKOFFICE_SALES_INVOICE_HISTORY_IMMUTABLE`. Tidak boleh
menonaktifkan trigger atau mengedit migration applied. Forward-fix additive
`20260910151000` menghitung ongkir sebelum core canonical berjalan, lalu trigger
Invoice memasukkan nilai tersebut ke row final agar response, operation snapshot,
schedule, dan audit lahir konsisten dalam satu kali write. Nilai transaction-local
dibersihkan setelah setiap call agar tidak terbawa ke Post/Cancel/Invoice lain.

## Kontrak bisnis

1. Ongkir SO default `0`, dapat diedit oleh role Sales yang sudah berwenang
   sebelum atau saat revisi SO yang masih diizinkan runtime existing.
2. Satu SO dapat memiliki beberapa Invoice. Total ongkir seluruh Regular
   Invoice berstatus `DRAFT`/`POSTED` tidak boleh melebihi ongkir SO.
3. Regular Invoice pertama otomatis memperoleh seluruh sisa ongkir. Nilainya
   dapat diedit sebelum posting. Regular Invoice berikutnya hanya memperoleh
   sisa yang belum dialokasikan.
4. Cancel Draft Invoice melepaskan alokasi ongkir. Posted Invoice immutable.
5. Down Payment Invoice selalu berongkir `0`.
6. Total tagihan Invoice dan seluruh schedule piutang memasukkan ongkir.
7. Jurnal memisahkan Product Revenue dan Delivery Fee Revenue; ongkir tidak
   digabung ke `SALES_REVENUE`.

## Impact map

Direct impact:

- kolom dan invariant pada `backoffice_sales_orders` serta
  `backoffice_sales_invoices`;
- snapshot/save RPC SO dan Draft Invoice;
- event/posting runtime Regular Invoice, receivable schedule, rule set Finance;
- form dan detail Quotation/SO Backoffice.

Downstream impact:

- `grand_total` SO/Invoice dan nominal schedule piutang;
- `financial_events.amounts` serta debit AR/credit pendapatan ongkir;
- converter cutover berikutnya dapat preserve delivery fee tanpa kehilangan
  nilai komersial.

Regression boundary:

- tabel/RPC `sales_headers` POS tidak dipanggil atau diubah;
- tidak ada efek Stock, Reservation, DO, FIFO, COGS, Payment, atau Cashier
  Session;
- tenant, role, optimistic version, operation UUID, exact retry, dan Finance
  period guard tetap memakai runtime canonical existing.
- event Backoffice Invoice lama yang belum mempunyai key `deliveryFeeAmount`
  dibaca sebagai nol; histori tidak dibackfill dan antrean HOLD lama tidak
  dipatahkan hanya karena penambahan field.

## Urutan manual — isolated Development saja

Jalankan **satu file penuh**, jangan menjalankan selection parsial.

Karena `20260910150000` sudah committed pada isolated Development, **jangan
jalankan ulang atau edit file tersebut**. Urutan lanjutan yang benar:

1. Jalankan [forward-fix preflight](../../supabase/diagnostics/backoffice_sales_delivery_fee_immutable_history_fix_preflight.sql).
   `immutable_history_failure_signature` dan `delivery_fee_trigger_before_fix`
   harus `SETUP`; hentikan bila ada `BLOCKER` atau SQL error.
2. Jalankan [forward-fix migration](../../supabase/migrations/20260910151000_backoffice_sales_delivery_fee_immutable_history_fix.sql).
3. Jalankan [forward-fix postflight](../../supabase/diagnostics/backoffice_sales_delivery_fee_immutable_history_fix_postflight.sql).
   Semua check selain `INFO` wajib `PASS`.
4. Jalankan [behavioral test yang diperbarui](../../supabase/tests/backoffice_sales_delivery_fee_parity_behavior.sql).
   Hasil akhir wajib satu row `PASS`; test juga membuktikan audit immutable sama
   dengan response canonical dan setting ongkir sementara tidak bocor.
5. Jalankan ulang forward-fix postflight dan kirim seluruh result set.

Jangan lanjut ke migration berikutnya jika salah satu gate gagal. Error harus
diaudit terhadap fungsi/tabel aktual Development; jangan memaksa data atau
menambal test agar sekadar hijau.

## Evidence lokal

- Exact source-anchor audit terhadap runtime `20260909161000`: 6/6 anchor
  masing-masing ditemukan tepat satu kali.
- Scoped ESLint `BackofficeSalesOrderView.tsx` dan
  `backoffice-sales-order.ts`: PASS.
- Next.js production build: PASS, termasuk TypeScript dan 81 static pages.
- Migration `20260910150000`: DATABASE LIVE pada isolated Development.
- Behavioral pertama: FAIL dengan bukti update audit immutable dari wrapper.
- Forward-fix `20260910151000`: DATABASE LIVE; user mengonfirmasi migration,
  postflight, behavioral, dan postflight ulang seluruhnya PASS pada isolated
  Development. Authenticated smoke dan UAT masih menunggu.

## Rollback / forward-fix

Forward-fix dibungkus transaksi dan seluruh guard/postcondition berjalan sebelum
ledger/commit. Kegagalan otomatis rollback. Migration `20260910150000` tetap
immutable. Trigger audit juga tetap aktif; tidak ada histori yang diubah atau
backfill. Setelah ada Invoice posted, koreksi finansial wajib memakai
reversal/adjustment canonical.

## Next safe step

Setelah migration, behavior, postflight, dan authenticated UI smoke lulus pada
isolated Development, lanjutkan **STEP 1E-B2/6**: converter atomik yang preserve
commercial/date/payment snapshot termasuk ongkir. Production rollout tetap
memerlukan compatibility preflight tersendiri dan instruksi eksplisit user.
