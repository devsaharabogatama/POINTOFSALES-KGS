# G4 Phase 48 — Customer Balance Readiness Preflight

## Tujuan

Phase 48 adalah audit SELECT-only sebelum Customer Balance (POS-006) dibuka.
Urutan ini dipilih karena Customer Balance menjadi dependency kelebihan bayar
TEMPO, refund ke saldo, dan settlement Ketul. Phase ini tidak mengaktifkan
entitlement, membuat ledger, mengubah `customers.current_balance`, atau membuka
payment method internal pada checkout.

## Menjalankan

Jalankan seluruh file berikut di Supabase SQL Editor:

```text
supabase/diagnostics/g4_phase48_customer_balance_preflight.sql
```

Kirim seluruh output `check_name,status,details`.

## Interpretasi

- `BLOCKER`: hentikan rollout dan kirim output. Jangan mengubah data langsung.
- `BACKFILL`: ada histori/cache/metode internal yang memerlukan rencana backfill
  eksplisit sebelum migration foundation dibuat.
- `SETUP`: schema/RPC canonical memang belum ada dan menjadi scope phase database
  berikutnya setelah seluruh blocker dipahami.
- `PASS`: invariant existing aman.
- `INFO`: inventaris untuk menentukan volume rollout.

`enabled_entitlement_without_canonical_foundation=BLOCKER` berarti toggle
Customer Balance sudah dinyalakan sebelum ledger tersedia. Matikan kembali dari
Pengaturan Modul; jangan mengosongkan `current_balance` atau mengedit Payment
Method internal secara manual.

## Yang Diaudit

- dependency Phase 46 dan feature catalog;
- entitlement per Company serta canonical schema/RPC gap;
- cache `customers.current_balance`, saldo negatif, dan Walk-In;
- histori payment `Customer_Balance` dan tenant/source Customer;
- kontrak Payment Method internal tanpa fee/clearing/bank;
- kategori transaksi receipt/usage dan account function liability;
- canonical Sale masih fail-closed untuk Customer Balance;
- browser tidak dapat mengubah `current_balance` langsung.

## Boundary Setelah Preflight

Hasil bersih hanya mengizinkan desain Phase 49 ledger/correction foundation.
Checkout usage, refund-to-balance, overpayment, exceptional settlement,
statement/export, TEMPO, Ketul, offline Customer Balance, dan jurnal G6 tetap
tertutup sampai phase masing-masing lulus.

