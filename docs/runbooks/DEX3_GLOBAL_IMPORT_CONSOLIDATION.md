# DEX-3 Global Import Consolidation

**Status:** USER UI SMOKE ACCEPTED; DEX-4 post-cutover matrix pending  
**Tanggal:** 2026-08-11  
**Migration:** tidak ada

## Outcome

Global Data Exchange sekarang memiliki tab `Import` untuk user yang mendapat
aksi Import dari catalog server. Implementasi memakai ulang pipeline Master
Import yang sudah aktif; tidak ada jalur tulis baru dan tidak ada bypass ke
table master.

```text
Data Exchange catalog (server-owned)
  -> IMPORT action untuk Company + role aktif
  -> fixed CSV template
  -> Master Import job API
  -> stage -> preview/validate -> explicit confirmation -> guarded commit
  -> job history/result/error rows
```

Import tetap hanya untuk `COMPANY_OWNER`, `COMPANY_ADMIN`, dan Super Admin.
Role lain tidak menerima action Import dari catalog dan direct call ke job API
tetap ditolak oleh guard server existing.

## Tipe Import yang Dipertahankan

1. Kategori Produk;
2. Satuan (UOM);
3. Gudang;
4. Supplier;
5. Kategori Pelanggan;
6. Chart of Account;
7. Kategori Transaksi;
8. Produk + seluruh Product-UOM sebagai satu atomic group;
9. Relasi Produk-Supplier;
10. Minimum Stock Produk-Gudang.

Opening Stock, transaksi posted/final, Stock/FIFO/Movement, Payment,
Financial Event, Journal, Company, Staff/password, role, dan entitlement tetap
workflow khusus. Laporan Finance tetap export-only. System-owned master tetap
diproteksi oleh validator/RPC existing.

## Compatibility

- `Inventory > Import & Export` belum dihapus pada DEX-3.
- Template, mapping, validator, preview, version check, partial commit, audit,
  serta history memakai component/API/RPC existing.
- Pemindahan navigation lama baru dilakukan pada DEX-4 setelah parity smoke.
- Tidak ada perubahan schema, data, grant, atau migration chain.

## Verification Lokal

Jalankan dari `backoffice`:

```powershell
npx.cmd eslint src/components/MasterImportView.tsx src/components/DataExchangeView.tsx src/app/page.tsx src/lib/data-exchange-server.ts src/app/api/data-exchange/catalog/route.ts src/app/api/master/import-jobs/route.ts 'src/app/api/master/import-jobs/[id]/route.ts'
npm.cmd run build
```

## Authenticated Smoke Wajib

1. Restart Backoffice dan hard refresh.
2. Login sebagai Company Owner/Admin, pilih Company aktif, lalu buka
   `Data Exchange > Import`.
3. Pastikan hanya sepuluh tipe di atas yang muncul.
4. Download satu template, upload fixture aman, jalankan preview/validate, dan
   pastikan error row dapat dibaca sebelum commit.
5. Pada database test, lakukan satu commit terkontrol dan pastikan result serta
   history sama dengan menu Inventory lama. Jangan commit fixture ke data live
   bila hanya menguji tampilan.
6. Login sebagai Finance, Store Manager, atau Warehouse Admin. Tab Import tidak
   boleh muncul; direct import-job request harus ditolak
   `MASTER_IMPORT_ADMIN_REQUIRED`.
7. Untuk user multi-Company, ganti Company lalu pastikan catalog, reference,
   preview, job, dan history tidak membawa data Company sebelumnya.
8. Ulangi satu template/preview dari `Inventory > Import & Export` untuk
   memastikan compatibility sebelum cutover.

## Rollback

Lepas rendering `MasterImportView` dari `DataExchangeView`. Karena tidak ada
schema/data mutation dan menu Inventory lama tetap tersedia, rollback tidak
menghilangkan job atau data import existing.

## Next Safe Step

User mengonfirmasi tampilan global masih sesuai ekspektasi pada 2026-08-11.
DEX-4 telah dibuka untuk menghapus navigation duplikat tanpa menghapus backend
compatibility route. Closing matrix berada di
`DEX4_INVENTORY_CUTOVER_AND_DEPLOYMENT_EVIDENCE.md`.
