# G4 Phase 17 — Offline Policy Backoffice UI

## Outcome

Menyediakan konfigurasi guarded untuk fondasi Offline POS yang sudah tersedia
di database tanpa mengaktifkan entitlement atau membuka checkout Offline.

Konfigurasi berada di `Pengaturan Modul` → `Point of Sale`:

- default persentase cadangan stok tingkat Company;
- optional override persentase per Toko;
- explicit eligibility per Terminal;
- status entitlement Offline POS read-only bagi user non-Super Admin.

Nama Company, Toko, dan Terminal dipakai pada tampilan. UUID serta kode teknis
tidak ditampilkan.

## Authority

- Super Admin dapat mengaktifkan/nonaktifkan entitlement dan mengatur seluruh
  policy pada active Company.
- Pemilik/Admin Perusahaan tidak dapat mengubah entitlement, tetapi dapat
  mengatur default Company, seluruh override Toko, dan Terminal.
- Store Manager hanya dapat mengatur override dan Terminal pada Toko assignment.

Route server memerlukan authenticated caller dan active Company. Mutation tidak
menulis tabel langsung; seluruh perubahan memakai
`save_pos_offline_allowance_policy(...)`, termasuk tenant/scope validation,
optimistic master version, advisory lock, dan audit.

## Verifikasi Lokal

Dari folder `backoffice`:

```powershell
npm.cmd run lint
npm.cmd run build
```

Hasil 30 Juli 2026:

- ESLint: PASS;
- Next.js production build dan TypeScript: PASS;
- route `/api/platform/offline-settings` terdaftar sebagai dynamic route.

## Smoke Manual

Entitlement harus tetap nonaktif selama smoke konfigurasi ini.

1. Restart Backoffice dan login sebagai Super Admin.
2. Pilih Company aktif, buka `Pengaturan Modul` → `Point of Sale`.
3. Pastikan status `POS Offline` tetap `Nonaktif`.
4. Ubah default Company, misalnya `20%`, lalu konfirmasi pada modal custom.
5. Buat/ubah override salah satu Toko.
6. Izinkan satu Terminal. Pastikan UI menjelaskan bahwa ini belum menerbitkan
   cadangan stok.
7. Tekan `Esc` pada modal konfirmasi lain; modal harus tertutup tanpa mutation.
8. Login sebagai Company Admin/Owner: toggle entitlement tidak tersedia,
   sedangkan default Company, Toko, dan Terminal dapat dikelola.
9. Login sebagai Store Manager: hanya Toko assignment yang terlihat; default
   Company tidak dapat diubah; override Toko/Terminal dapat dikelola.
10. Kembali ke PWA. Karena entitlement masih nonaktif, refresh snapshot harus
    tetap ditolak dengan `OFFLINE_POS_FEATURE_DISABLED`.

## Compatibility dan Boundary

- tidak ada migration/schema baru;
- tidak mengubah policy tanpa tindakan user;
- tidak mengaktifkan entitlement;
- tidak menerbitkan, merilis, atau mencabut allowance;
- tidak menghubungkan Keranjang ke retained queue;
- tidak membuka checkout/sync otomatis Offline;
- PWA online dan API existing tidak diubah.

## Next Safe Step

Setelah Phase-16 dan Phase-17 smoke PASS, bangun UI guarded untuk daftar dan
issue/release/force-revoke allowance per open Session–Product. Entitlement tetap
nonaktif sampai policy, allowance reconciliation, dan authenticated UAT lulus.
