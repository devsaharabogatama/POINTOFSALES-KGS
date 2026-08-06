# G4 Phase 30 — Expense Request/Approval Foundation Rollout

## Outcome

Membuka fondasi canonical Expense untuk kategori, kebijakan approval, serta
alur `DRAFT -> SUBMITTED -> APPROVED/REJECTED/CANCELED`. Phase ini **tidak**
mencairkan uang, mengubah `cashier_sessions.expected_cash`, membuat Cash In,
membuat drawer movement, atau memposting jurnal.

## Preconditions

- Phase 29 preflight tidak memiliki `BLOCKER`;
- ledger `20260803020000` tersedia;
- `public.cash_advances` tidak memiliki row yang membutuhkan backfill;
- jalankan file secara utuh dan berurutan, bukan potongan selection acak.

## Urutan Manual Supabase

1. Jalankan seluruh
   `supabase/migrations/20260803040000_g4_phase30_expense_request_approval_foundation.sql`.
2. Jalankan seluruh
   `supabase/diagnostics/g4_phase30_expense_request_approval_postflight.sql`.
3. Lanjut hanya bila seluruh check berstatus `PASS` dan
   `violation_rows = 0`.
4. Jalankan seluruh
   `supabase/tests/g4_phase30_expense_request_approval_tests.sql`.
5. Pastikan notice terakhir menyatakan test passed; seluruh fixture akan
   di-`ROLLBACK`.
6. Jalankan regression:

   - `supabase/tests/g4_phase26_sales_return_foundation_tests.sql`;
   - `supabase/tests/g4_phase2_cashier_session_foundation_tests.sql`;
   - `supabase/tests/g1_security_closure_tests.sql`.

## Expected Contract

- sembilan tabel canonical Expense tersedia dan RLS aktif;
- browser hanya memperoleh `SELECT`; mutation memakai RPC guarded;
- active Company mendapat default approval wajib dan kategori
  `Biaya Operasional Umum`;
- Company baru mendapat default yang sama setelah G2 provisioning selesai;
- entitlement `expense_enabled` tetap tidak aktif sampai Super Admin
  mengaktifkannya;
- Draft/Submit/Review/Cancel versioned dan diaudit;
- responsible party non-eksternal harus berasal dari Company aktif;
- legacy Cash Advance tetap dapat dibaca, tetapi hanya trigger pembuat event
  legacy yang dinonaktifkan;
- approval/cancel tidak membuat disbursement, drawer movement, stock movement,
  atau Finance posting final.

## Stop Conditions

Berhenti dan kirim error lengkap bila:

- migration gagal sebelum `COMMIT`;
- postflight menghasilkan satu saja `FAIL`;
- behavioral test tidak mencapai notice PASS;
- `expected_cash` berubah hanya karena request/approval;
- ada event runtime Expense sebelum phase disbursement dibuka.

Jangan rerun migration yang sudah masuk ledger. Buat forward-fix dengan version
lebih tinggi bila kegagalan ditemukan setelah migration berhasil di-commit.

## Rollback / Forward Fix

Migration ini additive. Sebelum ada dokumen nyata, rollback teknis dapat dibuat
sebagai migration baru yang mencabut RPC/grant dan menonaktifkan trigger
provisioning; jangan menghapus migration applied. Setelah ada histori, rollback
operasional adalah mematikan `expense_enabled`, menutup mutation RPC, dan
mempertahankan seluruh tabel/audit read-only. Perubahan schema setelah applied
wajib memakai forward-fix.

## Boundary Berikutnya

Sesudah rollout, postflight, behavior, dan regression dikonfirmasi PASS, next
safe step adalah UI/API request dan approval atau preflight disbursement sesuai
roadmap. Jangan membuka pencairan Cash/Transfer, settlement, return, Cash In,
offline Expense, Deposit, maupun jurnal G6 dalam Phase 30.
