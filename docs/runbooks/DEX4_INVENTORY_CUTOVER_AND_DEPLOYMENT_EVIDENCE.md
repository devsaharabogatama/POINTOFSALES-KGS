# DEX-4 Inventory Cutover and Deployment Evidence

**Status:** LOCAL-READY; post-cutover authenticated smoke pending  
**Tanggal:** 2026-08-11  
**Migration:** tidak ada

## Outcome

Global `Data Exchange` menjadi satu-satunya entry point Import/Export yang
terlihat di Backoffice. Link `Inventory > Import & Export` dan card/link lama
di app launcher dihapus agar user tidak melihat dua workflow yang identik.

Backend compatibility tetap dipertahankan:

- `MasterImportView` tetap dipakai oleh Global Data Exchange;
- template/export route tetap tersedia;
- staging, validation, commit, result, dan history job API tetap tersedia;
- guarded RPC dan seluruh server-side role/tenant/business validation tidak
  berubah;
- tidak ada schema, data, grant, atau migration yang berubah.

## Perubahan UI

```text
Sebelum
  Inventory -> Import & Export
  Data Exchange -> Export / Import

Sesudah
  Inventory -> master dan operasi Inventory saja
  Data Exchange -> Export / Import global
```

Data Exchange tetap tampil sebagai aplikasi global terpisah. Export mengikuti
akses masing-masing modul. Import hanya muncul bagi Company Owner/Admin dan
Super Admin sesuai catalog server.

## Verification Lokal

Jalankan dari `backoffice`:

```powershell
npx.cmd eslint src/app/page.tsx src/components/DataExchangeView.tsx src/components/MasterImportView.tsx src/lib/data-exchange-server.ts src/app/api/data-exchange/catalog/route.ts src/app/api/master/import-export/route.ts src/app/api/master/import-jobs/route.ts 'src/app/api/master/import-jobs/[id]/route.ts'
npm.cmd run build
```

Dari root repository:

```powershell
git diff --check
```

## Post-Cutover Authenticated Smoke

1. Restart Backoffice dan hard refresh.
2. Login Owner/Admin. Pastikan app launcher dan sidebar hanya mempunyai satu
   entry `Data Exchange`; `Inventory > Import & Export` sudah tidak ada.
3. Buka Inventory dan uji minimal Product, Gudang, Minimum Stock, Opening
   Stock, dan Stock Real untuk memastikan cutover tidak mengubah modulnya.
4. Buka Data Exchange dan pastikan tab Export serta Import tetap bekerja.
5. Download satu master CSV dan satu Finance XLSX yang diizinkan.
6. Jalankan template + preview satu import aman. Commit hanya pada fixture/test
   yang memang boleh mengubah data.
7. Login Finance/Accounting: Finance XLSX yang diizinkan terlihat, Import tidak
   terlihat, dan direct import API tetap ditolak.
8. Login Store Manager/Warehouse Admin: hanya export sesuai modul yang terlihat;
   Import dan Finance data di luar akses tidak terlihat/ditolak server.
9. Untuk user multi-Company, pindah Company dan ulangi catalog/export/preview;
   tidak boleh ada data, job, atau reference Company sebelumnya.
10. Pastikan history/result import lama masih dapat dibuka dari tab Import.

## Rollback

Tambahkan kembali navigation view lama yang merender `MasterImportView` pada
Inventory. Backend route/component tidak dihapus, sehingga rollback UI tidak
membutuhkan schema atau pemulihan data.

## Exit Criteria DEX

- satu visible entry point global;
- catalog UI dan action server konsisten;
- cross-role serta cross-Company negative smoke PASS;
- CSV/XLSX dan import parity PASS;
- backend compatibility tetap tersedia;
- tidak ada final/posted data yang dapat ditulis generic import;
- hasil dicatat sebagai deployment evidence sebelum Vercel Preview.

Setelah post-cutover smoke PASS, DEX-1 sampai DEX-4 dapat ditutup. Next roadmap
berpindah ke full pre-deploy E2E/regression, environment/Auth/secret review,
dan Vercel Preview readiness—bukan membuka Production langsung.
