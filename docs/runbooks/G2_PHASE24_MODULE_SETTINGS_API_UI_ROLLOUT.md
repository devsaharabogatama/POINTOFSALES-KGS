# G2 Phase 24 — Module Settings API/UI Rollout

## Outcome

Super Admin memiliki menu **Pengaturan Modul** untuk mengelola entitlement
Company berdasarkan katalog `platform_features`. Company target mengikuti
selector workspace aktif. Perubahan selalu melewati RPC
`set_company_feature`, mempertahankan `config` existing, dan tercatat oleh
`company_feature_audit`.

## Boundary

- menu dan API hanya untuk profile `super_admin`;
- Company Owner/Admin tidak dapat membuka atau memanggil mutation API;
- toggle hanya mengubah entitlement, bukan menyatakan modul siap produksi;
- konfigurasi bisnis detail tetap berada pada menu modulnya;
- tidak ada raw JSON config editor;
- katalog module/feature tidak dapat dimutasi melalui UI ini;
- perubahan meminta konfirmasi dan modal dapat ditutup dengan Escape.

Contoh boundary Tax:

- **Pengaturan Modul** menyalakan `tax_sales_enabled` atau
  `tax_purchase_enabled`;
- **Aturan Pajak** mengatur nama, rate, account, dan effective date;
- Product/Category assignment, resolver, checkout calculation, dan journal
  tetap mengikuti gate terpisah.

## File

- `backoffice/src/app/api/platform/module-settings/route.ts`;
- `backoffice/src/components/ModuleSettingsView.tsx`;
- integrasi menu Super Admin di `backoffice/src/app/page.tsx`.

## Evidence Lokal

```text
npm run lint   PASS
npm run build  PASS
/api/platform/module-settings terdeteksi sebagai dynamic route
```

## Manual Smoke

1. restart Backoffice dan login sebagai Super Admin;
2. pilih Company target pada selector workspace;
3. buka **Pengaturan Modul**;
4. pilih **Sales**, aktifkan **Pajak Penjualan**, dan konfirmasi;
5. buka **Aturan Pajak** lalu pastikan kartu Sales aktif dan tombol tambah
   tersedia untuk scope Penjualan;
6. kembali ke Settings, nonaktifkan lagi bila Company belum masuk UAT Tax;
7. ganti Company dan pastikan entitlement antar-Company tidak tercampur;
8. login role non-Super Admin dan pastikan menu tidak tampil serta API menolak;
9. tekan Escape pada confirmation modal dan pastikan tidak ada perubahan;
10. smoke menu existing.

Jangan menyalakan Offline, Tempo, Customer Balance, Ketul, atau Tax untuk
operasional hanya karena toggle tersedia. Masing-masing tetap membutuhkan gate
dependency dan UAT modulnya.

## Next Safe Step

Setelah smoke Settings dan Tax Master lulus, lanjutkan guarded assignment Tax
Rule ke Product Category/Product. Tax resolver tetap deferred.
