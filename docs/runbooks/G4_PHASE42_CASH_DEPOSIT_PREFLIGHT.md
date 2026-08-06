# G4 Phase 42 — Cash Deposit Preflight

Status: `READY FOR MANUAL PREFLIGHT`

Phase 41 Additional Expense UI sudah local-ready. Sesuai roadmap POS-008,
langkah berikutnya hanya diagnostic SELECT-only untuk Setor Kas multi-sesi.
Belum ada schema, RPC, mutation, UI, atau jurnal Deposit baru pada fase ini.

## Boundary yang diaudit

- legacy `bank_deposits` satu sesi dan scope backfill-nya;
- sesi `CLOSED`, actual closing cash, dan kandidat sesi belum disetor;
- tenant/store/session integrity dan identitas/nominal legacy;
- duplicate session allocation serta coverage Financial Event legacy;
- trigger legacy yang masih aktif;
- kesiapan Transaction Category `CASH_DEPOSIT`;
- kesiapan fungsi akun Cash Drawer, Main Cash, Cash in Transit, Bank,
  Under-deposit Control, dan Cash Overage Liability;
- direct browser write boundary;
- gap canonical policy, header, session lines, audit, variance exception,
  allocation, dan guarded RPC.

Preflight tidak menghitung opening cash sebagai jurnal dan tidak menyamakan
session closing variance dengan deposit variance.

## Cara menjalankan

1. Buka Supabase SQL Editor.
2. Jalankan seluruh file
   `supabase/diagnostics/g4_phase42_cash_deposit_preflight.sql`.
3. Kirim semua baris `check_name,status,details`.

## Interpretasi

- `BLOCKER`: jangan membangun foundation sebelum data/reference diperbaiki.
- `REVIEW`: histori/trigger legacy membutuhkan keputusan compatibility eksplisit.
- `BACKFILL`: data legacy valid tetapi harus dimigrasikan secara terencana.
- `SETUP`: gap canonical yang memang diharapkan sebelum foundation.
- `PASS`: invariant bersih.
- `INFO`: inventaris, bukan kegagalan.

## Expected pada database sekarang

- enam canonical table dan empat guarded RPC: `SETUP`;
- legacy trigger dapat muncul `REVIEW` walau histori Deposit masih nol;
- direct mutation `authenticated`: seluruhnya `false`;
- dependency, tenant, value, Session, category, dan account readiness harus
  `PASS` sebelum migration dirancang.

## Stop condition

Jangan lanjut jika ada `BLOCKER`. Output `REVIEW` atau `BACKFILL` harus dibaca
berdasarkan jumlah baris dan tidak boleh diabaikan. Phase ini tidak membuka
Deposit UI, variance resolution, bank reconciliation, atau jurnal final G6.
