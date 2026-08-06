# G4 Phase 43 — Cash Deposit Foundation Rollout

## Outcome

Phase ini membuka foundation server Setor Kas multi-sesi sesuai POS-008:

- satu dokumen dapat memilih beberapa Cashier Session `CLOSED` dalam Company
  dan Store yang sama;
- expected per sesi dihitung server dari actual closing cash dikurangi saldo
  sesi berikutnya dan alokasi deposit final sebelumnya;
- Draft belum mengunci sesi, Submit mengunci sesi, Reject/Cancel melepasnya,
  dan Approve membuatnya final;
- actual deposit boleh matched, kurang, atau lebih;
- variance yang disetujui membuka exception kontrol, bukan otomatis menjadi
  biaya atau pendapatan;
- Approve membuat Financial Event `BANK_DEPOSIT` berstatus `HOLD` sampai G6;
- browser hanya dapat mutasi melalui RPC guarded.

Belum dibuka: UI Setor Kas, bank matching, variance resolution/allocation,
offline Deposit, correction/reversal, dan journal posting final G6.

## Urutan manual

Jalankan satu per satu di Supabase SQL Editor:

1. `supabase/migrations/20260804130000_g4_phase43_cash_deposit_foundation.sql`
2. `supabase/diagnostics/g4_phase43_cash_deposit_postflight.sql`
3. `supabase/tests/g4_phase43_cash_deposit_foundation_tests.sql`
4. ulangi `supabase/diagnostics/g4_phase43_cash_deposit_postflight.sql`
5. regression:
   - `supabase/tests/g4_phase40_additional_expense_disbursement_tests.sql`
   - `supabase/tests/g4_phase37_expense_settlement_tests.sql`
   - `supabase/tests/g4_phase34_expense_disbursement_tests.sql`
   - `supabase/tests/g4_phase2_cashier_session_foundation_tests.sql`
   - `supabase/tests/g1_security_closure_tests.sql`

Expected:

- seluruh row postflight selain inventory `INFO` berstatus `PASS`;
- behavioral test mengeluarkan `TEST PASSED` dan rollback;
- tidak ada perubahan data dari behavioral test;
- regression lama tetap lulus.

## Compatibility dan forward-fix

- `public.bank_deposits` serta trigger legacy tidak dihapus, tetapi tidak
  digunakan oleh runtime baru;
- migration berhenti bila legacy deposit muncul setelah preflight karena
  expected/variance historis tidak boleh ditebak;
- Session final tidak dibuka kembali;
- bila migration gagal sebelum `COMMIT`, perbaiki file yang belum applied lalu
  jalankan ulang dari awal;
- bila migration sudah applied, jangan edit file migration: buat forward-only
  migration baru.

## Manual smoke setelah rollout

UI belum dibuka pada phase ini. Smoke operasional dilakukan setelah phase UI:

- dua sesi `CLOSED` dapat digabung;
- saldo sesi berikutnya mengurangi expected;
- Submit mencegah sesi dipakai dokumen lain;
- Reject/Cancel melepas lock;
- Approve matched tidak membuat exception;
- Approve under/over membuat tepat satu exception dan satu Financial Event
  `HOLD` tanpa journal G6.
