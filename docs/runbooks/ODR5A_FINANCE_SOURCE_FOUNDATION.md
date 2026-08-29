# ODR-5A Finance Source Foundation

Status: `LOCAL READY`  
Migration: `20260828210000`

## Tujuan

Menambah foundation zero-backfill untuk dua final effect yang berbeda:

1. satu sumber Finance immutable per operasi Dispatch;
2. satu request verifikasi per payment intent POS.

Fase ini belum membuat Financial Event atau jurnal dan belum mengubah Stock,
FIFO, `sales_payments`, invoice, maupun histori Sale lama.

## Urutan manual

1. Jalankan migration:
   [`20260828210000_odr_phase5a_finance_source_foundation.sql`](../../supabase/migrations/20260828210000_odr_phase5a_finance_source_foundation.sql)
2. Jalankan postflight:
   [`odr_phase5a_finance_source_foundation_postflight.sql`](../../supabase/tests/odr_phase5a_finance_source_foundation_postflight.sql)
3. Jalankan behavioral fixture-free:
   [`odr_phase5a_finance_source_foundation_behavior.sql`](../../supabase/tests/odr_phase5a_finance_source_foundation_behavior.sql)
4. Jalankan postflight sekali lagi.

Expected:

- seluruh check selain inventory `PASS`;
- inventory `INFO`;
- `dispatchEffects=0` dan `paymentRequests=0` karena migration tidak backfill;
- permission baru tetap `SHADOW` sampai runtime dan UI siap.

## Yang ditambahkan

- `sales_dispatch_financial_effects` dan append-only audit;
- `sales_payment_verification_requests` dan append-only audit;
- system event `SALE_DISPATCHED` dan `SALE_PAYMENT_VERIFIED`;
- account function `CUSTOMER_ADVANCE_LIABILITY` tanpa memaksakan akun COA;
- RLS dan browser direct-table closure;
- permission shadow `finance.sales_payment_verification`.

## Forward fix / rollback

Migration additive dan zero-backfill. Jika migration gagal, transaksi rollback
utuh dan ledger tidak terisi. Setelah berhasil, jangan drop relation karena
runtime berikutnya akan menjadikannya source immutable; koreksi memakai forward
migration sebelum ODR-5B.

## Next safe step

Setelah closing postflight PASS, jalankan preflight mapping
`CUSTOMER_ADVANCE_LIABILITY` dan transaction category/rule. ODR-5B baru boleh
mengaitkan Dispatch ke Financial Event melalui controlled posting. Jangan
mengaktifkan automatic posting pada fase ini.
