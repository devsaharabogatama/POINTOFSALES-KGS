# ACP-4F Stock Adjustment Permission Preflight

Status: READY TO RUN; SELECT-only; belum melakukan permission cutover.

## Tujuan

Mengaudit complete-cutover `inventory.stock_adjustments` setelah ACP-4E live
PASS. Slice ini harus memisahkan VIEW, Create/Edit Draft, Post, dan Cancel tanpa
mengubah hitungan stok, FIFO, Movement, Finance event, atau role baseline.

Stock Opname adalah consumer khusus: saat Opname diposting, server membuat dan
mem-posting Adjustment canonical. Jalur internal ini harus tetap berjalan bagi
user yang berwenang atas Opname tanpa memberinya akses Adjustment mandiri.

## Jalankan

Jalankan file berikut secara utuh di Supabase SQL Editor:

`supabase/diagnostics/acp_phase4f_stock_adjustment_permission_preflight.sql`

Kirim seluruh output. File hanya berisi satu statement SELECT dan tidak
mengubah permission, dokumen, Stock, FIFO, Movement, atau audit.

## Interpretasi

- `BLOCKER`: berhenti; perbaiki sebelum enforcement.
- `REVIEW`: boundary desain yang wajib ditutup dalam ACP-4F.
- `SETUP`: gap runtime yang expected sebelum migration.
- `PASS`: invariant live aman.
- `INFO`: inventory existing untuk compatibility dan sizing.

Expected sebelum implementasi:

- direct read/reference dan trusted path Opname berstatus `REVIEW`;
- composed read RPC dan tiga mutation hook berstatus `SETUP`;
- permission key masih `SHADOW`;
- seluruh invariant data, tenant, lifecycle, FIFO, Movement, dan privilege
  berstatus `PASS`.

## Target sesudah output direview

1. `VIEW` menjaga navigation, list/detail, Reason, serta narrow Product/Gudang.
2. `CREATE_DRAFT` dan `EDIT_DRAFT` menjaga Save berdasarkan identitas/status.
3. `POST` menjaga posting atomic, FIFO allocation, Movement, dan Finance event.
4. `CANCEL_FINAL` menjaga pembatalan Draft sesuai baseline yang telah disetujui.
5. Stock Opname memakai trusted private core, bukan bypass capability publik.
6. Browser direct SELECT ditutup setelah semua consumer aktif pindah ke RPC.
7. Preset hanya mengurangi role; tidak pernah menaikkan hak baseline.
