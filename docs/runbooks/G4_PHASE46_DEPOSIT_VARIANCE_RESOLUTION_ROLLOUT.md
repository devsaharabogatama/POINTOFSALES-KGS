# G4 Phase 46 — Deposit Variance Resolution Foundation Rollout

## Outcome

Phase ini membuka foundation server penyelesaian selisih Setor Kas sesuai
POS-008:

- Finance/Owner/Admin dapat menetapkan user internal yang bertanggung jawab
  atas `UNDER_DEPOSIT`, disertai alasan dan audit;
- resolusi dapat dialokasikan sebagian dan selalu append-only;
- uang ditemukan/pengganti dan refund dapat diproses langsung dengan account
  function Kas/Bank yang valid;
- write-off, beban Company, pendapatan selisih lebih, dan source correction
  wajib maker-checker;
- request yang ditolak tidak membuat allocation atau Financial Event;
- setiap allocation approved membuat Financial Event
  `DEPOSIT_VARIANCE_RESOLUTION` berstatus `HOLD` sampai Finance G6;
- exact retry memakai idempotency key yang sama dan tidak menggandakan effect;
- browser tidak memperoleh direct table write.

Belum dibuka: UI resolution, bank matching otomatis, reversal/replacement
source, Offline Deposit, jurnal final, dan report Finance G6.

## Baseline yang disetujui

Preflight Phase 45 menunjukkan:

- seluruh dependency, source, amount, lifecycle, account catalog, privilege,
  dan reconciliation berstatus `PASS`;
- satu Cash Deposit approved berstatus matched, sehingga belum ada exception
  atau allocation yang perlu di-backfill;
- enam kelompok `SETUP` tepat merupakan schema/RPC/event contract Phase 46.

Migration sengaja berhenti bila exception/allocation muncul setelah preflight.
Data historis tersebut harus dirancang backfill-nya secara eksplisit dan tidak
boleh ditebak.

## Urutan manual

Jalankan satu per satu di Supabase SQL Editor:

1. `supabase/migrations/20260804160000_g4_phase46_deposit_variance_resolution.sql`
2. `supabase/diagnostics/g4_phase46_deposit_variance_resolution_postflight.sql`
3. `supabase/tests/g4_phase46_deposit_variance_resolution_tests.sql`
4. ulangi `supabase/diagnostics/g4_phase46_deposit_variance_resolution_postflight.sql`
5. regression:
   - `supabase/tests/g4_phase43_cash_deposit_foundation_tests.sql`
   - `supabase/tests/g4_phase40_additional_expense_disbursement_tests.sql`
   - `supabase/tests/g4_phase37_expense_settlement_tests.sql`
   - `supabase/tests/g1_security_closure_tests.sql`

Expected:

- seluruh row postflight selain inventory `INFO` berstatus `PASS`;
- behavioral test mengeluarkan `TEST PASSED` lalu `ROLLBACK`;
- test membuktikan partial recovery, exact retry, maker tidak dapat menyetujui
  request sendiri, reviewer terpisah dapat approve/reject, dan cross-Company
  lookup ditolak;
- regression lama tetap lulus.

## Compatibility dan forward-fix

- dokumen Setor Kas/Session final tidak dibuka atau diubah;
- allocation lama tidak ditulis ulang; baseline live memang nol row;
- event resolution masih `HOLD`, sehingga migration ini tidak mengklaim jurnal
  double-entry final;
- jika migration gagal sebelum `COMMIT`, perbaiki file yang belum applied dan
  jalankan ulang dari awal;
- jika ledger `20260804160000` sudah ada, jangan edit/rerun migration—buat
  forward-only migration baru.

Rollback produksi setelah applied tidak dilakukan dengan drop/destructive SQL.
Nonaktifkan entry point UI (belum ada pada phase ini), pertahankan history, dan
gunakan forward-fix.

## Manual smoke setelah rollout

Belum ada UI pada phase ini. Smoke operasional dilakukan pada phase UI
berikutnya dengan actor Finance sebagai maker dan Owner/Admin berbeda sebagai
reviewer. Jangan memakai satu actor untuk kedua sisi maker-checker.
