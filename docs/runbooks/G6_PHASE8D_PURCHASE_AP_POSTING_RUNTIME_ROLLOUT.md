# G6 Phase 8D — Purchase/AP Posting Runtime Rollout

Runtime ini memasang posting atomic untuk `GOODS_RECEIPT`, `SUPPLIER_INVOICE`,
dan `SUPPLIER_PAYMENT`. Migration tidak memproses sembilan historical HOLD.

## Urutan wajib

1. Jalankan
   `supabase/migrations/20260814140000_g6_phase8d_purchase_ap_posting_runtime.sql`.
2. Jalankan forward-fix wajib
   `supabase/migrations/20260814143000_g6_phase8d_zero_value_receipt_event_fix.sql`.
   Ini menangani Receipt seluruhnya ditolak/Rp0 tanpa membuat jurnal nol.
3. Jalankan
   `supabase/diagnostics/g6_phase8d_zero_value_receipt_event_fix_postflight.sql`.
4. Jalankan
   `supabase/diagnostics/g6_phase8d_purchase_ap_posting_runtime_postflight.sql`.
   Semua baris selain inventory `INFO` harus `PASS`.
5. Jalankan
   `supabase/tests/g6_phase8d_purchase_ap_posting_runtime_tests.sql`.
   Test menutup zero-effect Receipt, memproses event positif, menguji replay,
   lalu `ROLLBACK`.
6. Jalankan ulang kedua postflight. Semua check harus tetap `PASS` dan sembilan HOLD
   tetap tersedia.

Berhenti pada error atau `FAIL`. Jangan memproses historical HOLD secara live
sebelum controlled queue scope dan live reconciliation Phase berikutnya dibuat.

## Accounting contract

- Goods Receipt: Debit Inventory, Credit AP Provisional.
- Goods Receipt yang seluruh source nilainya tepat Rp0 ditutup sebagai
  `CANCELED / NO_FINANCIAL_EFFECT` tanpa jurnal nol.
- Supplier Invoice: Debit AP Provisional, Debit/Credit signed purchase variance
  plus nonrecoverable tax, Debit recoverable Input Tax, Credit AP Final.
- Supplier Payment: Debit AP Final, Credit immutable Cash/Bank source account.

Semua amount dihitung ulang dari source final. Account snapshot wajib masih
tenant-valid, aktif, postable, dan compatible. Retry event yang telah POSTED
mengembalikan jurnal yang sama tanpa efek kedua.

## Forward fix

Migration bersifat additive. Jika rollout gagal, transaksi migration rollback
otomatis. Setelah commit, jangan drop runtime yang telah dipakai; buat migration
forward-fix dan pertahankan jurnal/event append-only.
