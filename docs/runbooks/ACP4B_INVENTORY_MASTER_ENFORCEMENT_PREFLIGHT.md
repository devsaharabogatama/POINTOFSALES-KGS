# ACP-4B Inventory Master Enforcement Preflight

Status: SELECT-only diagnostic local-ready.

## Tujuan

Mengaudit satu cutover key lengkap, `inventory.master_data`, setelah ACP-4A.
Preflight ini belum mengaktifkan override dan tidak mengubah data.

Jalur yang harus siap dalam satu batch:

- navigation `Master Inventory`;
- read API Kategori Produk, UOM, Gudang, Store, Terminal;
- mutation identity Kategori Produk, UOM, Gudang;
- assignment Pajak Kategori yang muncul pada halaman yang sama;
- direct table dan direct RPC bypass;
- absent override tetap sama dengan role baseline.

## Interpretasi

- `BLOCKER`: jangan membuat enforcement migration;
- `SETUP`: objek/hook memang belum dibuat dan menjadi scope migration berikut;
- `PASS`: invariant siap;
- `INFO`: inventory untuk review, bukan kegagalan.

Column-level grant diperiksa terpisah karena `has_table_privilege` saja dapat
terlihat aman walaupun browser masih memiliki `INSERT(column)` atau
`UPDATE(column)`.

## Langkah manual

Jalankan
`supabase/diagnostics/acp_phase4b_inventory_master_enforcement_preflight.sql`
dan kirim seluruh output. Jangan mengubah `enforcement_status`, grant, atau row
override secara manual.
