# ACP-4G Stock Opname Permission Preflight

Status: READY TO RUN; SELECT-only; belum melakukan permission cutover.

## Tujuan

Mengaudit complete-cutover `inventory.stock_opnames` setelah ACP-4F live PASS.
Slice ini harus memisahkan Backoffice report/review/post dari channel blind
count Kasir, sekaligus menjaga Store/Gudang scope, nonblocking Movement window,
recount, supersede, idempotency, dan posting Adjustment canonical.

Opening Stock dan Minimum Stock tidak termasuk fase ini.

## Jalankan

Jalankan file berikut secara utuh di Supabase SQL Editor:

`supabase/diagnostics/acp_phase4g_stock_opname_permission_preflight.sql`

Kirim seluruh output. File hanya berisi satu statement SELECT dan tidak
mengubah permission, Opname, Stock, FIFO, Movement, Adjustment, atau audit.

## Interpretasi

- `BLOCKER`: berhenti; perbaiki sebelum enforcement.
- `REVIEW`: boundary desain yang wajib ditutup dalam ACP-4G.
- `SETUP`: gap runtime yang expected sebelum migration.
- `PASS`: invariant live aman.
- `INFO`: inventory existing untuk compatibility dan sizing.

Expected sebelum implementasi:

- direct read, reference scope, dan pemisahan Backoffice/blind-count berstatus
  `REVIEW`;
- composed read RPC dan permission hook berstatus `SETUP`;
- permission key masih `SHADOW`;
- lifecycle, tenant, attempt, supersede, Adjustment proof, idempotency,
  Stock–Movement, FIFO, dan privilege berstatus `PASS`.

## Target sesudah output direview

1. `VIEW` menjaga navigation dan report Backoffice lengkap.
2. Blind payload Kasir tetap tidak pernah memuat system/expected/physical/
   variance quantity dari sesi.
3. `CREATE_DRAFT`/`EDIT_DRAFT` menjaga create, start, count, dan complete tanpa
   memperluas Store/Gudang scope Kasir.
4. `REVIEW` menjaga request recount setelah sesi completed.
5. `POST` menjaga posting Opname melalui private Adjustment core yang telah
   dibuktikan ACP-4F.
6. `CANCEL_FINAL` menjaga cancel sesi nonfinal sesuai baseline owner/reviewer.
7. Browser direct SELECT ditutup setelah Backoffice pindah ke composed RPC.
8. Preset hanya mengurangi role dan tidak pernah mengubah blind-count menjadi
   akses laporan Backoffice.

## Stop condition

Jangan membuat atau menjalankan migration ACP-4G bila ada `BLOCKER`, data
reconciliation gagal, atau channel Kasir tidak dapat dipertahankan tanpa
permission bypass. Jangan membuka Opening Stock/Minimum Stock pada fase ini.
