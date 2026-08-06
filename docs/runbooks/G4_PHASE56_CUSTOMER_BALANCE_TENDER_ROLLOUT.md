# G4 Phase 56 — Customer Balance Tender Rollout

Membuka Saldo Customer sebagai metode pembayaran Sale ONLINE. Seluruh saldo
lama wajib digunakan; jika saldo melebihi total, checkout ditolak dan Cashier
harus menambah belanja sebesar kekurangannya.

Tetap tertutup: Offline Customer Balance, refund-to-balance, Ketul, TEMPO,
exceptional settlement, izin Stock minus, dan jurnal final G6.

## Urutan Manual

1. Migration `supabase/migrations/20260805160000_g4_phase56_customer_balance_tender.sql`.
2. Postflight `supabase/diagnostics/g4_phase56_customer_balance_tender_postflight.sql`; seluruh row wajib `PASS`.
3. Behavior `supabase/tests/g4_phase56_customer_balance_tender_tests.sql`; wajib notice `TEST PASSED` lalu `ROLLBACK`.
4. Regression Phase 52, Phase 49, Phase 8, Phase 4, Phase-10 stress preflight,
   G3 Phase-14, dan G1 security closure.
5. Rerun postflight Phase 56 sebagai closing reconciliation.

Jalankan satu file penuh per eksekusi di Supabase SQL Editor.

Contract: tepat satu leg sebesar seluruh saldo lama; Payment, ledger DEBIT,
cache, audit, receipt, dan Financial Event HOLD atomik serta idempotent;
ACTIVE/WIND_DOWN boleh debit; WIND_DOWN otomatis DISABLED ketika liability nol;
browser tidak mendapat direct write. Signature public Post tetap kompatibel.

Setelah database gate PASS, lanjut UI POS auto-fill Saldo Customer. Berikutnya
STK-006 negative-stock foundation dibuat sebagai migration terpisah.
