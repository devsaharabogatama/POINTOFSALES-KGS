# ACP-6D Customer Balance Permission Preflight

Permission key: `finance.customer_balances`.

Jalankan hanya:

1. `supabase/diagnostics/acp_phase6d_customer_balance_permission_preflight.sql`.
2. Kirim seluruh output `check_name,status,details`.
3. Berhenti jika terdapat `BLOCKER` atau `BACKFILL` yang tidak diperkirakan.

Diagnostic ini SELECT-only. Ia tidak mengubah policy, saldo Customer, request,
ledger, payment, Financial Event, Journal, grant, RLS, RPC, maupun permission.

Boundary yang dinilai:

- list, antrean koreksi, dan statement Backoffice memakai effective `VIEW`;
- pengajuan koreksi memakai `MANAGE`, sedangkan keputusan memakai
  `APPROVE/REVIEW` dan tetap maker-checker;
- kredit lebih bayar dan pembayaran dengan saldo di POS tetap memakai
  authority Sale/open-session sendiri, bukan authority Backoffice;
- Customer master tetap dimiliki `contacts.customers` dan hanya referensi
  Customer sempit yang dibuka;
- Walk-In tidak boleh memiliki saldo dan cache Customer harus sama dengan
  ledger immutable;
- correction, ledger, payment source, audit, Financial Event, dan tenant tetap
  satu rantai yang dapat direkonsiliasi;
- direct table read baru dicabut setelah seluruh consumer dipindahkan;
- ACP tidak mem-posting event `HOLD` dan tidak membuat Journal.

Smoke test ACP-6B sampai ACP-6D ditunda secara eksplisit ke closing UAT
gabungan. Status smoke tetap `PENDING` sampai benar-benar dijalankan.
