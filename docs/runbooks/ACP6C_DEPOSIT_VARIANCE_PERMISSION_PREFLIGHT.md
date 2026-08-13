# ACP-6C Deposit Variance Permission Preflight

Permission key: `finance.deposit_variances`.

Jalankan hanya:

1. `supabase/diagnostics/acp_phase6c_deposit_variance_permission_preflight.sql`.
2. Kirim seluruh output `check_name,status,details`.
3. Berhenti jika terdapat `BLOCKER` atau `BACKFILL` yang tidak diperkirakan.

Diagnostic ini SELECT-only. Ia tidak mengubah exception, request, allocation,
Setor Kas, Financial Event, Journal, grant, RLS, RPC, maupun permission.

Boundary yang dinilai:

- list/detail Backoffice menggunakan effective `VIEW`;
- penetapan penanggung jawab dan pengajuan resolusi memakai `MANAGE`;
- keputusan beban, pendapatan, write-off, dan source correction tetap
  maker-checker serta tidak dapat disetujui pembuatnya sendiri;
- resolusi parsial tidak melampaui sisa exception;
- allocation, request, audit, dan Financial Event tetap satu rantai;
- event resolusi tetap `HOLD`, tanpa posting Journal oleh ACP;
- referensi Setor Kas bersifat sempit dan tidak mewariskan authority Setor Kas;
- direct table read baru dicabut setelah consumer Backoffice dipindahkan.
