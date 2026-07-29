# G2 Phase 47 — Minimum Stock API/UI

## Outcome

Backoffice menyediakan konfigurasi Minimum Stock per pasangan Product–Gudang
dan fixed CSV Import/Export tanpa mengubah saldo atau membuat dokumen inventory.

## Execution Path

- UI: `MinimumStockView` pada modul Inventory;
- API list/create: `/api/master/minimum-stock`;
- API update: `/api/master/minimum-stock/[id]`;
- mutation: guarded RPC `save_product_warehouse_stock_setting`;
- import: job type `PRODUCT_WAREHOUSE_MINIMUM_STOCK`;
- storage: `product_warehouse_stock_settings` dan audit terkait.

Browser tidak memperoleh direct write ke tabel settings maupun tabel saldo.
Authorization, active Company, valid Product/Gudang, Base-UOM precision,
optimistic version, duplicate pair, dan audit tetap ditegakkan database.

## Fixed CSV

Template create:

```csv
product_sku,warehouse_name,minimum_stock_base_qty,low_stock_alert_enabled
```

Export update menambahkan `internal_id`. SKU Product dan nama Gudang adalah
referensi user-facing. `minimum_stock_base_qty` selalu memakai Base UOM.

## Verification Lokal

```powershell
cd backoffice
npm.cmd run lint
npm.cmd run build
```

Expected:

- lint tanpa error/warning;
- build sukses;
- route `/api/master/minimum-stock` dan
  `/api/master/minimum-stock/[id]` terdeteksi.

## Authenticated Smoke

1. restart Backoffice dan buka **Inventory → Minimum Stock**;
2. buat setting Product/Gudang yang belum dikonfigurasi;
3. pastikan label threshold menunjukkan nama Base UOM, bukan kode/UUID;
4. aktifkan notifikasi dan pastikan threshold kosong ditolak;
5. uji Product integer dengan angka desimal dan pastikan ditolak;
6. edit threshold existing dan pastikan berhasil;
7. buka dua tab, simpan versi lama, dan pastikan conflict meminta reload;
8. pastikan `Escape` menutup modal;
9. pada **Import & Export**, unduh template dan export Minimum Stock;
10. preview satu CREATE, UPDATE, SKIP, dan row error bila memungkinkan;
11. commit data valid dan pastikan hasil tampil kembali di halaman Minimum
    Stock.

Setelah create/edit/import, verifikasi jumlah/quantity pada `product_stocks`
dan `stock_movements` tidak berubah. Tidak boleh ada Stock Request atau
Supplier Order yang terbentuk.

## Compatibility dan Rollback

- tidak ada migration baru pada Phase 47;
- Product, Gudang, Product-UOM, saldo, movement, dan import type lama tidak
  diubah;
- rollback UI cukup mengembalikan file Phase 47; data setting tetap canonical
  dan aman;
- jangan mengedit/rerun migration `20260728090000`.
