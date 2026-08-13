# ACP-4D Stock Read-Model Enforcement Rollout

Status: LOCAL READY; manual Supabase rollout and authenticated smoke pending.

## Boundary yang diubah

ACP-4D menegakkan tepat dua permission:

- `inventory.stock_real` untuk halaman saldo aktual komposit dan export-nya;
- `inventory.stock_movements` untuk Kartu Stok immutable dan export-nya.

Stock Real tidak lagi menarik seluruh FIFO layer dan Movement ledger ke browser.
RPC server menghitung valuasi FIFO, minimum stock, dan Movement terakhir per
Produk-Gudang. Kartu Stok memakai RPC terpisah sehingga user yang hanya boleh
melihat saldo tidak otomatis memperoleh ledger Movement lengkap.

Raw `product_stocks`, `product_batches`, dan `stock_movements` tetap SELECT-only,
tenant/RLS-scoped untuk workflow operasional lama yang memang memerlukannya.
Ini bukan bypass Stock Real: halaman, export, navigation, dan API komposit wajib
memakai permission masing-masing; client tidak dapat mengirim purpose untuk
memperluas akses.

## Urutan SQL manual

Jalankan setiap file utuh di Supabase SQL Editor. Hentikan pada error atau row
postflight berstatus `FAIL`.

1. `supabase/migrations/20260812160000_acp_phase4d_stock_read_model_enforcement.sql`
2. `supabase/diagnostics/acp_phase4d_stock_read_model_postflight.sql`
3. `supabase/tests/acp_phase4d_stock_read_model_tests.sql`
4. ulangi langkah 2
5. `supabase/diagnostics/acp_phase4_inventory_pilot_preflight.sql`

Expected behavioral notice:

`TEST PASSED: Stock Real and Stock Movement permissions are separated, tenant-safe, read-only, and role-compatible.`

## Smoke Backoffice

Restart Backoffice setelah migration, lalu gunakan Company Admin untuk mengubah
permission satu user Inventory:

1. `LIHAT_SAJA` Stock Real: halaman saldo dapat dibuka, export Stock Real tidak
   muncul dan direct export ditolak.
2. `TANPA_AKSES` Kartu Stok: Home/Fast Link tidak menampilkan Kartu Stok dan
   direct route/API ditolak.
3. Pastikan Stock Real tetap tidak memuat ledger mentah di Network response;
   payload hanya berisi saldo komposit dan Gudang.
4. `IKUTI_ROLE`: akses kembali sama dengan baseline role.
5. Ulangi pada Company kedua dan pastikan override tidak terbawa lintas Company.
6. Jalankan satu workflow Transfer/Adjustment/Opname yang memang diizinkan
   role; reference on-hand tetap terbaca dan tidak mengubah invariant
   Stock-Movement-FIFO.
7. Di Data Exchange, Stock Real dan Kartu Stok hanya muncul bila capability
   `EXPORT` efektif tersedia. CSV menampilkan nama/kode bisnis dan nomor dokumen,
   bukan UUID sumber.

## Compatibility dan recovery

Tidak ada Stock, FIFO, Movement, minimum-stock, atau dokumen operasional yang
ditulis ulang. Signature RPC operasional lama tidak berubah. Pemisahan ini hanya
menambah dua read RPC dan mengganti active Backoffice read path.

Jangan mengembalikan direct write grant atau mengubah migration yang sudah
applied. Jika smoke gagal, gunakan `IKUTI_ROLE` sebagai recovery per-user dan
buat forward fix; jangan membuat client-side bypass.
