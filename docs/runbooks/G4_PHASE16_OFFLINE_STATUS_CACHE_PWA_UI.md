# G4 Phase 16 — Read-Only Offline Status/Cache PWA UI

## Outcome

Menampilkan kesiapan Offline secara transparan pada PWA tanpa membuka checkout
Offline. Cashier dapat melihat koneksi, exact scope, snapshot terakhir, usia
snapshot, jumlah Product ber-allowance, dan local available allowance yang
sudah dikurangi retained queue.

## UI

Status tersedia setelah Cashier Session terbuka melalui tombol `Offline` pada
header. Tombol memiliki indikator cache dan membuka drawer saat dibutuhkan,
sehingga tidak mengambil ruang tetap pada katalog/keranjang. Drawer memuat:

- status `Snapshot tersimpan` atau `Belum ada snapshot`;
- badge `Cache tersedia` atau `Checkout diblokir`;
- nama Terminal dan Gudang, bukan UUID/kode internal;
- nomor Session;
- waktu snapshot server dan usia cache yang diperbarui setiap menit;
- jumlah Product yang memiliki allowance;
- maksimal empat ringkasan allowance Product;
- pesan bahwa status masih read-only;
- tombol `Perbarui snapshot` yang hanya aktif ketika browser online.

## Lifecycle

- saat Session terbuka, PWA membaca retained cache exact Session;
- library cache di-load secara lazy setelah Session, bukan pada layar Login;
- refresh selalu melalui `get_pos_offline_catalog_snapshot`;
- feature/policy yang belum aktif ditampilkan sebagai pesan lokal drawer dan
  tidak menjadi error transaksi global;
- saat Session berhasil ditutup atau user logout, cache di-invalidasi dengan
  alasan dan timestamp tanpa menghapus record;
- kegagalan invalidasi IndexedDB tidak boleh membuat close Session server yang
  sudah sukses terlihat gagal;
- ketika browser offline, cache tetap read-only dan tombol refresh disabled;
- tombol Draft/Post tetap disabled ketika offline seperti sebelumnya.

## Verifikasi Lokal

Dari folder `pwa`:

```powershell
npm.cmd run lint
npm.cmd run build
```

Hasil 30 Juli 2026:

- `oxlint`: PASS;
- TypeScript/Vite production build: PASS;
- main JS `471.65 kB` (`133.18 kB` gzip);
- lazy Offline cache chunk `102.84 kB` (`33.59 kB` gzip);
- tidak ada chunk-size warning;
- service worker/precache generation: PASS.

Smoke browser otomatis tidak tersedia pada sesi agent ini. Jangan menandai
authenticated UI smoke PASS sebelum langkah manual di bawah dijalankan.

## Smoke Manual — Current Closed Entitlement

1. Restart PWA.
2. Login dan lanjutkan Cashier Session yang masih `OPEN`.
3. Pastikan panel besar tidak lagi memenuhi workspace. Klik tombol `Offline`
   pada header dan pastikan drawer `Status Offline` terbuka.
4. Pastikan Terminal, Gudang, dan nomor Session pada drawer sesuai header aktif.
5. Expected awal: `Belum ada snapshot` dan `Checkout diblokir`.
6. Klik `Perbarui snapshot`.
7. Expected: pesan `Mode Offline belum diaktifkan oleh Super Admin untuk
   Company ini.`
8. Putuskan koneksi browser.
9. Expected: header `Offline diblokir`; tombol refresh disabled; tombol
   Draft/Post tetap disabled.
10. Sambungkan kembali dan pastikan transaksi online biasa tidak berubah.
11. Tutup drawer memakai `Esc`, tombol tutup, dan klik backdrop.

## Boundary

- tidak mengaktifkan `offline_pos_enabled`;
- tidak membuat Terminal policy;
- tidak menerbitkan allowance;
- tidak membuat payload Keranjang Offline;
- tidak mencetak Slip Offline;
- tidak menjalankan sync otomatis;
- tidak membuka direct browser write atau service-role;
- status `Cache tersedia` tidak berarti checkout Offline sudah diizinkan.

## Next Safe Step

Setelah closed-entitlement smoke PASS, bangun guarded Backoffice configuration
untuk:

1. Company default allowance percentage;
2. optional Store override;
3. explicit Terminal eligibility;
4. issue/release/revoke allowance per Session/Product.

Super Admin tetap satu-satunya role yang mengaktifkan entitlement. Setelah
konfigurasi dan audit UI lulus, jalankan authenticated UAT snapshot + allowance
reconciliation sebelum membuka payload Keranjang Offline.
