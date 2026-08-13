# ACP-6B Cash Deposit Permission Preflight

Permission key: `finance.cash_deposits`.

Jalankan hanya:

1. `supabase/diagnostics/acp_phase6b_cash_deposit_permission_preflight.sql`.
2. Kirim seluruh output `check_name,status,details`.
3. Berhenti jika terdapat `BLOCKER` atau `BACKFILL` yang tidak diperkirakan.

Diagnostic ini SELECT-only. Ia tidak mengubah dokumen Setor Kas, Session,
drawer, variance, Financial Event, Journal, grant, RLS, RPC, maupun permission.

Boundary yang dinilai:

- Backoffice list/detail dan approve/reject memakai effective capability;
- Cashier tetap menyiapkan sesi `CLOSED` yang eligible melalui Store authority;
- Session hanya boleh terkunci pada satu setoran aktif/final;
- Reject/cancel melepaskan Session, approve memfinalkan allocation;
- approval menghasilkan tepat satu Financial Event `HOLD` dan exception hanya
  bila ada variance;
- `finance.deposit_variances` tetap permission terpisah;
- direct table read baru boleh dicabut setelah Backoffice, PWA, dan Variance
  consumer dipindahkan ke RPC masing-masing.

