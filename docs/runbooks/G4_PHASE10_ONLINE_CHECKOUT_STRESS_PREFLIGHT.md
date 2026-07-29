# G4 Phase 10 — Online Checkout Stress Preflight

## Tujuan

Memastikan runtime Sale online siap diuji end-to-end dan dengan dua request
Post yang benar-benar berjalan bersamaan. Preflight ini tidak membuat Sale,
Payment, Movement, FIFO allocation, atau Financial Event.

## Menjalankan

Jalankan seluruh file berikut di Supabase SQL Editor:

```text
supabase/diagnostics/g4_phase10_online_checkout_stress_preflight.sql
```

Kirim seluruh hasil `check_name,status,details`.

## Interpretasi

- `BLOCKER`: hentikan stress test dan perbaiki invariant lebih dahulu.
- `SETUP` pada `concurrent_checkout_fixture_readiness`: database aman, tetapi
  belum ada satu Store dengan dua user operasional aktif, Terminal, Payment
  Method, serta pasangan saldo/FIFO positif untuk true concurrency.
- `PASS`: invariant dan fixture minimum tersedia.
- `INFO`: inventori/boundary, bukan kegagalan.

## Fixture Minimum True Concurrency

- dua user Auth aktif yang efektif boleh memakai POS pada Store yang sama:
  `CASHIER`/`STORE_MANAGER` ter-assign, Company Owner/Admin, atau Super Admin;
- sedikitnya satu Terminal aktif;
- satu Gudang `is_sale_source` aktif pada Store;
- satu Product stok dengan saldo dan FIFO positif;
- satu Payment Method eligible.

Jangan memakai satu akun pada dua request untuk mengakali setup karena Session
canonical memang one-open per Cashier. Jangan menjalankan Post stress sebelum
seluruh `BLOCKER` bersih.

Revision note: versi awal diagnostic salah membaca public wrapper setelah
Phase 6/8 dan tidak menghitung inherited Company/Super Admin access. Versi
terbaru membaca `public.post_pos_sale` untuk outer Sale lock,
`private.post_pos_sale_core` untuk stock/FIFO/idempotency, serta effective POS
users sesuai runtime.

## Boundary

Offline queue, Customer Balance, Ketul Offset, Return/Refund, Expense, Deposit,
dan settlement tetap tertutup. Hasil preflight menentukan apakah next step
adalah setup fixture atau harness true-concurrent online checkout.
