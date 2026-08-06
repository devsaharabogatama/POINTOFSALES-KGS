# G4 Phase 19 — Offline Allowance Operations UI

## Outcome

Backoffice menyediakan area operasional untuk:

- melihat allowance aktif dan riwayat allowance pada active Company;
- memilih Cashier Session `OPEN` yang berada dalam scope role;
- memilih Product stock dengan saldo positif pada Gudang penjualan sesi;
- menerbitkan allowance melalui
  `issue_pos_offline_stock_allowance(...)`;
- release allowance milik actor sendiri;
- force-revoke allowance sesi lain dengan alasan wajib.

UI berada pada `Pengaturan Modul` → `Point of Sale` setelah bagian kebijakan
Offline POS.

## Authority dan invariant

- route memerlukan authenticated user dan active Company;
- akses hanya Super Admin, Company Owner/Admin, atau Store Manager;
- Store Manager tetap dibatasi oleh RLS dan validasi RPC pada Store assignment;
- browser hanya membaca tabel scoped dan tidak memperoleh `INSERT/UPDATE/DELETE`;
- semua mutation diteruskan ke RPC Phase 11;
- jumlah allowance dihitung ulang server dari policy dan stok belum
  dicadangkan;
- optimistic `master_version`, queue blocker, reason, invalidation, dan audit
  tetap ditegakkan server-side;
- allowance adalah reservation, bukan Movement atau pengurangan stok;
- checkout Offline dan koneksi Keranjang ke queue tetap tertutup.

## File

- API:
  `backoffice/src/app/api/platform/offline-allowances/route.ts`;
- UI:
  `backoffice/src/components/OfflineAllowanceOperations.tsx`;
- integrasi:
  `backoffice/src/components/OfflinePosSettings.tsx`.

Tidak ada migration baru. Schema dan RPC canonical berasal dari migration
Phase 11 yang sudah applied.

## Verification lokal

Dari folder `backoffice`:

```powershell
npm.cmd run lint
npm.cmd run build
```

Hasil 30 Juli 2026:

- ESLint PASS;
- TypeScript/Next.js production build PASS;
- route `/api/platform/offline-allowances` terdaftar.

Konektor browser lokal tidak tersedia pada verification agent, sehingga
authenticated visual smoke tidak diklaim.

## Authenticated smoke

Gunakan development/staging dan stok disposable.

1. Restart Backoffice.
2. Login sebagai Super Admin dan pilih Company test.
3. Buka `Pengaturan Modul` → `Point of Sale`.
4. Pastikan bagian `Cadangan Stok per Sesi` muncul.
5. Dengan entitlement nonaktif, tombol `Terbitkan allowance` harus disabled.
6. Untuk UAT issuance saja, aktifkan entitlement melalui toggle Super Admin,
   pastikan default Company dan satu Terminal test eligible.
7. Pastikan ada Cashier Session `OPEN` dan Product dengan stok positif.
8. Pilih sesi dan Product lalu terbitkan allowance.
9. Pastikan allowance muncul sebagai `Aktif`, jumlah memakai nama Base UOM,
   dan stok on-hand tidak berkurang.
10. Login sebagai Store Manager pada Store yang sama; hanya sesi scoped yang
    boleh terlihat.
11. Force-revoke allowance sesi lain. Modal harus meminta alasan dan dapat
    ditutup dengan Escape tanpa mutation.
12. Pastikan status menjadi `Dicabut` dan alasan tampil.
13. Uji release biasa hanya pada allowance milik actor yang sama.
14. Nonaktifkan kembali entitlement setelah UAT bila checkout Offline belum
    dibuka.
15. Jalankan kembali reconciliation/postflight Phase 11 dan Phase 12 bila UAT
    membuat allowance/submission nyata.

## Compatibility

- online Sale, PWA cart, Session, stock balance, FIFO, dan Movement tidak
  diubah;
- pengaturan policy Phase 17 tetap memakai route/RPC lama;
- active allowance lama tetap dapat diselesaikan ketika entitlement dimatikan;
- direct stock/allowance table write browser tetap tertutup;
- tidak ada auto-issue allowance ketika Session dibuka.

## Next safe step

Setelah authenticated role/UAT lulus, sediakan kontrol allowance milik Cashier
di menu Offline PWA dan lakukan reconciliation cache–allowance. Jangan
hubungkan Keranjang ke offline queue sampai issuance/release, stale snapshot,
network reconnect, duplicate retry, dan force-revoke conflict UX terbukti.
