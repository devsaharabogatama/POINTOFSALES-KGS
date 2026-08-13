# ACP-4E Stock Transfer Permission Preflight

Status: READY TO RUN; SELECT-only; no permission cutover yet.

## Tujuan

Mengaudit complete-cutover `inventory.stock_transfers` setelah ACP-4D live PASS.
Satu key baru hanya boleh menjadi ENFORCED bila navigation, read/reference,
Draft mutation, Post, Cancel, direct URL/API/RPC, tenant isolation, FIFO,
Movement, idempotency, dan audit ditutup bersama.

## Jalankan

Jalankan file berikut secara utuh di Supabase SQL Editor:

`supabase/diagnostics/acp_phase4e_stock_transfer_permission_preflight.sql`

Kirim seluruh output. Diagnostic hanya satu statement SELECT dan tidak mengubah
catalog, override, dokumen Transfer, Stock, FIFO, Movement, atau audit.

## Interpretasi

- `BLOCKER`: wajib nol sebelum implementasi enforcement dibuat.
- `REVIEW`: boundary desain yang harus diselesaikan dalam slice ACP-4E.
- `SETUP`: gap runtime expected sebelum migration, bukan izin untuk dilewati.
- `PASS`: invariant live aman.
- `INFO`: inventory existing untuk sizing dan compatibility.

Expected sebelum implementasi:

- direct read cutover `REVIEW`, karena tabel Transfer masih browser-readable;
- reference consumer `REVIEW`, karena Finance/Accounting viewer tidak boleh
  dipaksa mempunyai akses Master Inventory hanya untuk nama Gudang;
- composed read RPC dan tiga mutation hook `SETUP`;
- permission key tetap `SHADOW`.

## Target implementasi setelah review

1. `VIEW` menjaga navigation, list/detail, narrow Product/Gudang references,
   dan composed read RPC.
2. `CREATE_DRAFT`/`EDIT_DRAFT` menjaga Save sesuai status dokumen.
3. `POST` menjaga atomic FIFO relocation dan paired Movement.
4. `CANCEL_FINAL` menjaga pembatalan Draft sesuai baseline role.
5. Preset hanya mengurangi role; `OPERASIONAL` tidak pernah memperoleh POST.
6. Browser table read ditutup setelah semua consumer aktif pindah ke RPC.
7. Tidak ada perubahan flow, stock math, FIFO, idempotency, atau role baseline.
