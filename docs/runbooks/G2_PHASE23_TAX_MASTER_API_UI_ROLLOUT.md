# G2 Phase 23 — Tax Master API/UI Rollout

## Outcome

Backoffice menyediakan menu **Aturan Pajak** untuk membaca serta mengelola
master Sales/Purchase Tax melalui RPC `save_tax_rule`. UI tidak menulis tabel
Tax secara langsung dan tidak mengaktifkan entitlement, resolver, kalkulasi,
checkout Tax, Supplier Invoice Tax, jurnal, atau pelaporan resmi.

## Boundary

- entitlement `tax_sales_enabled` dan `tax_purchase_enabled` tetap independen;
- hanya Super Admin yang dapat mengubah entitlement melalui boundary platform;
- role Finance/Accounting/Company Owner/Admin hanya dapat menyimpan Tax Rule
  pada scope yang entitlement-nya sudah aktif;
- Sales selalu inclusive dan memakai akun Liability/Pajak Keluaran;
- Purchase memakai akun Asset/Pajak Masukan dan wajib menentukan recoverable;
- edit membuat version baru; histori lama tidak ditimpa;
- nama Tax/akun menjadi label utama, kode hanya informasi sekunder;
- Escape menutup modal;
- assignment Product Category/Product dan resolver transaksi tetap deferred.

## File

- `backoffice/src/lib/tax-master.ts`;
- `backoffice/src/app/api/master/tax-rules/route.ts`;
- `backoffice/src/app/api/master/tax-rules/[id]/route.ts`;
- `backoffice/src/components/TaxMasterView.tsx`;
- integrasi navigasi pada `backoffice/src/app/page.tsx`.

## Local Evidence

```text
backoffice npm run lint   PASS
backoffice npm run build  PASS
route /api/master/tax-rules dan /api/master/tax-rules/[id] terdeteksi
```

## Manual Smoke

1. restart Backoffice setelah phase-22 migration sudah applied;
2. login sebagai user Company aktif lalu buka **Aturan Pajak**;
3. pastikan status Pajak Penjualan dan Pajak Pembelian sama dengan entitlement
   Company serta tidak muncul schema-cache error;
4. jika kedua entitlement nonaktif, pastikan tombol tambah disabled dan UI
   menjelaskan bahwa aktivasi hanya oleh Super Admin;
5. bila salah satu entitlement memang sudah diaktifkan untuk UAT, buat Draft
   pada scope itu, lalu edit dan pastikan version bertambah;
6. pastikan scope nonaktif tidak dapat dipilih/disimpan;
7. pastikan Sales hanya inclusive dan menampilkan akun Liability, sedangkan
   Purchase menampilkan akun Asset serta pilihan recoverable;
8. tekan Escape dan pastikan modal tertutup;
9. smoke menu existing.

Jangan mengaktifkan entitlement hanya untuk melewati smoke. State nonaktif
merupakan hasil yang valid dan wajib tetap aman.

## Next Safe Step

Setelah smoke menu Tax stabil, buat fase terpisah untuk guarded assignment Tax
Rule ke Product Category/Product. Resolver dan kalkulasi transaksi belum boleh
dibuka pada fase assignment tersebut.
