# ODR-5D Payment Verification Runtime Preflight

Preflight ini mengaudit sumber pembayaran Order ODR sebelum server membuka
workflow verifikasi Finance dan settlement Journal. File bersifat SELECT-only:
tidak membuat request, Cash drawer movement, Event, queue, atau Journal.

## Jalankan

Jalankan satu file berikut melalui Supabase SQL Editor:

`supabase/diagnostics/odr_phase5d_payment_verification_runtime_preflight.sql`

Kirim seluruh output dan hentikan rollout bila ada `BLOCKER`.

## Hasil yang diharapkan

- dependency ODR-5A, ODR-5B, dan ODR-5C `PASS`;
- queue Finance dan Offline submission aktif nol;
- source verification masih nol sebelum runtime dipasang;
- payment intent Order mempunyai UUID, nominal, Payment Method, dan bukti yang
  valid;
- total intent non-TEMPO sama dengan total Order; TEMPO tidak boleh melebihi
  total Order;
- exact account mapping serta approved Posting Rule `PASS`;
- permission dan runtime berstatus `SETUP` memang expected;
- tiga scope `REVIEW` mengunci Advance sebelum Dispatch, settlement sesudah
  Dispatch, dan hubungan pembayaran Cash dengan sesi Kasir.

## Kontrak yang akan dipasang setelah PASS

1. Confirmed Order menghasilkan request immutable dari payment intent server;
2. Finance melakukan verify/reject secara maker-checker dan idempotent;
3. verifikasi sebelum Dispatch: debit Cash/Bank, kredit Uang Muka Customer;
4. verifikasi setelah Dispatch: debit Cash/Bank, kredit Clearing atau Piutang;
5. Dispatch berikutnya memakai Uang Muka yang sudah diverifikasi tanpa
   menggandakan kas maupun pendapatan;
6. jurnal tetap melalui controlled queue sampai closing reconciliation selesai;
7. Payment dan Journal Sale legacy tidak diubah.

UI Finance baru tetap bagian ODR-6. Mode `AUTOMATIC` juga tetap ditutup sampai
runtime, behavioral, closing postflight, dan smoke ODR-5D seluruhnya lulus.
