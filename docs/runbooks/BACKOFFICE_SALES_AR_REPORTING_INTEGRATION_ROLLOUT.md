# Backoffice Sales AR/Reporting Integration — Step 3/3

Status awal: **LOCAL READY; MANUAL ISOLATED-DEVELOPMENT SQL GATE PENDING**.

Target tunggal: Supabase Development `fkywtxucmyjvpwdiqpix`. Jangan jalankan
paket ini pada production `nbxjslqojexjfogamnjt` atau staging lama
`yjxpddwrjdczuqyix`.

## Impact map

- Direct: reader existing Penerimaan Customer, Save/Post routing Customer
  Receipt, AR Aging, Customer Statement, dan Excel export.
- Downstream: satu Receipt boleh mengalokasikan satu pembayaran nyata ke
  Invoice Retail dan/atau Backoffice milik Customer/Company yang sama. Header,
  Financial Event, dan Journal tetap satu.
- Compatibility: FK allocation Retail dan Backoffice tetap terpisah. Payload
  legacy `salesId` pada API dipetakan eksplisit menjadi `RETAIL_SALE`; runtime
  Retail/ODR dan Customer Balance advance tetap tersedia.
- Tidak berubah: SO/Quotation, Invoice/DO/SJ, Stock, Reservation, FIFO/HPP,
  POS checkout, Payment Term final, template dokumen, atau data historis.
- Concurrency/retry: Save/Post tetap memakai canonical row lock, optimistic
  version, idempotency key, dan outstanding recheck dari Step 1/3.
- Rollback: migration ini mengganti tiga reader dan menambah satu wrapper.
  Setelah dipakai, jangan menghapusnya secara ad-hoc. Forward-fix dengan
  migration timestamp baru; dokumen/Journal final tetap immutable.

## Urutan manual wajib

1. Jalankan seluruh [preflight](../../supabase/diagnostics/backoffice_sales_ar_reporting_integration_preflight.sql).
   Stop jika ada `BLOCKER`/`FAIL`.
2. Jalankan seluruh [migration](../../supabase/migrations/20260911163000_backoffice_sales_ar_reporting_integration.sql).
3. Hard refresh schema/API, lalu jalankan [postflight](../../supabase/diagnostics/backoffice_sales_ar_reporting_integration_postflight.sql).
   Stop jika ada `FAIL`/`BLOCKER`; baris `INFO` bukan bukti behavior.
4. Jalankan seluruh [behavioral Customer Receipt + Backoffice](../../supabase/tests/backoffice_sales_payment_collection_behavior.sql).
   Test membuat fixture canonical dan seluruh write di-rollback.
5. Jalankan regression [ODR compatibility](../../supabase/tests/odr_phase6d_consumer_compatibility_behavior.sql).
   Test AR lama `finance_ar_reporting_behavioral_test.sql` sengaja tidak
   dijadikan gate otomatis karena membutuhkan Invoice TEMPO Retail existing dan
   akan menghasilkan precondition error pada Development yang belum mempunyai
   fixture tersebut. Cabang Retail diverifikasi lewat contract postflight dan
   authenticated smoke aktual pada langkah 7; zero row tidak disebut PASS.
6. Jalankan kembali [postflight](../../supabase/diagnostics/backoffice_sales_ar_reporting_integration_postflight.sql).
7. Restart client Development, hard refresh, lalu authenticated smoke:
   - Invoice Backoffice `POSTED` dan belum lunas muncul di Penerimaan Customer;
   - Invoice Retail existing tetap muncul dan dapat dialokasikan;
   - satu Draft dapat memuat kedua source untuk Customer yang sama;
   - stale version, over-allocation, Company lain, dan role tanpa izin ditolak;
   - setelah Post, satu Journal terbentuk dan outstanding kedua source turun;
   - AR Aging menunjukkan label Retail/Backoffice dan installment yang benar;
   - Customer Statement dan kedua Excel export menunjukkan sumber dokumen;
   - exact retry tidak membuat Receipt/Journal kedua;
   - Customer Balance advance existing tetap dapat disimpan/diposting.

## Status closure

Bedakan hasil berikut: `LOCAL READY`, `DATABASE LIVE`, `CLIENT DEPLOYED`,
`SMOKE PASS`, dan `UAT PASS`. Step 3/3 belum selesai hanya karena migration,
lint, build, atau postflight PASS.
