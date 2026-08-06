# G5 Phase 11 — Supplier Invoice Matching Foundation Rollout

## Outcome

Phase ini membuka database foundation Supplier Invoice dan three-way matching:

```text
Supplier Order
-> Goods Receipt / AP Provisional
-> Supplier Invoice tervalidasi / AP Final HOLD
```

Supplier Payment, jurnal final, Debit/Credit Note resolution, serta revaluasi
FIFO/HPP final tetap tertutup sampai fase lanjut/G6.

## Kontrak yang Dibuka

- Draft/HOLD/VALIDATED/CANCELED dengan optimistic `master_version`;
- invoice supplier eksternal unik per Supplier dan nomor internal otomatis;
- allocation many-to-many memakai immutable Receipt/AP/Order line ID;
- partial invoice dan residual AP provisional;
- invoice yang belum sepenuhnya dialokasikan masuk HOLD;
- price variance menghasilkan MATCHED/WITHIN_TOLERANCE/EXCEPTION;
- default tolerance server adalah nol, dengan optional override Supplier;
- Purchase Tax INCLUSIVE/EXCLUSIVE memakai calculator canonical dan snapshot;
- validasi idempotent, row-lock provisional, audit, serta Financial Event HOLD;
- harga beli terakhir Product-Supplier hanya diperbarui dari invoice VALIDATED;
- Supplier Invoice tidak menulis Stock, FIFO, atau Stock Movement;
- Supplier Return pada provisional yang baru terinvoice sebagian diblokir sampai
  split AP Provisional/Supplier Credit tersedia agar tidak salah klasifikasi.

## Urutan Manual

1. Jalankan seluruh migration:
   `supabase/migrations/20260806100000_g5_phase11_supplier_invoice_matching_foundation.sql`.
2. Jalankan seluruh postflight:
   `supabase/diagnostics/g5_phase11_supplier_invoice_matching_postflight.sql`.
3. Semua row non-`INFO` wajib `PASS` dengan `violation_rows = 0`.
4. Jalankan behavioral test rollback-safe:
   `supabase/tests/g5_phase11_supplier_invoice_matching_tests.sql`.
5. Jalankan regression berikut:
   - `supabase/tests/g5_phase8_purchase_return_foundation_tests.sql`;
   - `supabase/tests/g5_phase5_goods_receipt_foundation_tests.sql`;
   - `supabase/tests/g5_phase2_stock_request_supplier_order_tests.sql`;
   - `supabase/tests/g1_security_closure_tests.sql`.
6. Rerun postflight Phase 11 sebagai closing verification.

Migration yang sudah sukses jangan dijalankan ulang. Jika suatu langkah gagal,
kirim error lengkap dan hentikan pada langkah tersebut.

## Expected Data State

`supplier_invoice_matching_scope = BACKFILL` dari preflight bukan kegagalan.
Itu berarti AP provisional Receipt existing menjadi kandidat allocation awal.
Migration tidak membuat invoice palsu atau menutup residual tersebut otomatis.

## Compatibility dan Forward Fix

- Goods Receipt, Purchase Return, Stock, FIFO, dan Movement historis tidak
  ditulis ulang.
- Trigger AP provisional diperketat per tanggung jawab: identity/nilai Receipt
  tetap immutable, hanya transisi status `OPEN -> MATCHED/REVERSED` yang sah.
- Partial-invoice Purchase Return fail-closed sampai allocation split tersedia.
- Bila migration gagal, transaksi PostgreSQL melakukan rollback penuh. Setelah
  migration berhasil, koreksi dilakukan melalui migration maju baru; jangan
  mengedit file migration ini.

## Exit Boundary

Phase 11 dinyatakan database-complete hanya setelah migration, seluruh
postflight, behavioral, regression, dan closing postflight sukses. Backoffice
Supplier Invoice, valuation adjustment, Supplier Payment, serta jurnal G6 belum
boleh disebut aktif pada boundary ini.
