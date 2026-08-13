# ACP-4I Minimum Stock Permission Preflight

Status: USER-VERIFIED; live output tanpa `BLOCKER` menjadi input enforcement.

## Tujuan

Mengaudit slice Inventory terakhir `inventory.minimum_stock` setelah ACP-4H
live PASS, tanpa mengubah schema, permission, setting, saldo, Movement, import,
atau notifikasi. Diagnostic memeriksa:

- catalog role/capability dan status `SHADOW`;
- tabel setting/audit, guarded optimistic mutation, tenant, threshold Base UOM,
  duplicate pair, audit, serta nonterminal import job;
- direct browser read/write dan kebutuhan composed RPC;
- ketergantungan halaman saat ini pada Product reference, Master Warehouse, dan
  Stock Real;
- capability enforcement pada global export dan type-aware import;
- keputusan scope Store Manager sebelum runtime enforcement.

## Menjalankan

Jalankan seluruh file berikut sebagai satu query:

[`supabase/diagnostics/acp_phase4i_minimum_stock_permission_preflight.sql`](../../supabase/diagnostics/acp_phase4i_minimum_stock_permission_preflight.sql)

Kirim seluruh row `check_name,status,details`.

## Interpretasi

- `BLOCKER`: hentikan; data/dependency/boundary wajib dikoreksi sebelum build.
- `REVIEW`: keputusan/cutover yang harus diselesaikan pada enforcement.
- `SETUP`: komponen target memang belum tersedia.
- `PASS`: invariant existing aman.
- `INFO`: inventory saja.

Expected pada state sebelum ACP-4I adalah composed read RPC dan capability hook
mutation/import berstatus `SETUP`, ditambah direct-read/shared-consumer serta
Store-scope `REVIEW`. `BLOCKER` wajib nol.

## Boundary

Preflight tidak mengaktifkan alert baru dan tidak membuat Stock Request atau
Supplier Order. Notice Minimum Stock tetap non-blocking. Jangan menutup direct
SELECT atau mengubah global Data Exchange sebelum seluruh consumer aktif sudah
dipindahkan ke authority `inventory.minimum_stock`.
