# G4 Phase 20 — Cashier Offline Allowance PWA UI

## Outcome

Drawer `Offline` pada PWA sekarang memberi Cashier kontrol terbatas atas
cadangan stok milik sesi aktif:

- meminta cadangan untuk Product stok yang tersedia;
- melihat jumlah server, quantity pada antrean lokal, dan sisa lokal;
- melepaskan cadangan miliknya yang belum dikonsumsi dan tidak dipakai antrean;
- menyelaraskan kembali snapshot server setelah setiap mutation.

Phase ini tidak membuka checkout Offline, penyerahan barang, pembayaran,
Slip Offline, atau eksekusi antrean.

## Authority dan invariant

- PWA hanya memanggil RPC canonical
  `issue_pos_offline_stock_allowance(uuid,uuid)` dan
  `release_pos_offline_stock_allowance(uuid,bigint,boolean,text)`.
- Cashier Session, Company, Store, Terminal, Gudang, actor, feature, policy,
  stock yang belum direservasi, Base UOM, precision, dan jumlah allowance
  diverifikasi server.
- Client tidak mengirim jumlah allowance.
- Release selalu `p_force = false`; force revoke tetap hanya tersedia bagi
  Manager/Admin di Backoffice.
- Tombol release dinonaktifkan jika retained queue lokal masih memakai Product
  tersebut. Server tetap mengulang pemeriksaan queue/consumption/version.
- Mutation yang sukses wajib diikuti refresh authoritative catalog snapshot.
  Bila refresh/reconciliation gagal, cache lama di-invalidasi dan tidak boleh
  tetap terlihat valid.
- Allowance adalah reservation, bukan Stock Movement dan bukan pengurangan
  stock on-hand.

## File

- `pwa/src/lib/offlineCatalog.ts`
- `pwa/src/App.tsx`
- `pwa/src/App.css`

Tidak ada migration atau perubahan schema pada phase ini.

## Verifikasi lokal

Dari folder `pwa`:

```powershell
npm.cmd run lint
npm.cmd run build
```

Hasil 30 Juli 2026:

- `oxlint`: PASS;
- TypeScript + Vite production build: PASS;
- PWA service worker/precache generation: PASS;
- chunk Offline tetap lazy-loaded;
- browser visual automation tidak tersedia pada environment agent, sehingga
  authenticated tablet smoke belum diklaim.

## Authenticated UAT

Gunakan development/staging dan Product disposable.

1. Di Backoffice, pastikan entitlement Offline aktif sementara, default
   Company valid, Toko/Terminal eligible, dan stok Product positif.
2. Login PWA sebagai Cashier assigned lalu buka sesi pada Terminal tersebut.
3. Buka menu `Offline`, klik `Perbarui snapshot`.
4. Pilih Product pada `Tambah cadangan produk`, lalu klik `Minta cadangan`.
5. Konfirmasi memakai modal custom. `Esc` harus menutup tanpa mutation.
6. Expected: Product muncul pada daftar, quantity server sama dengan quantity
   lokal bila belum ada queue, dan stock on-hand tidak berkurang.
7. Muat ulang drawer/snapshot. Allowance yang sama harus tetap satu, bukan
   terduplikasi.
8. Klik `Lepaskan`, konfirmasi, lalu pastikan Product hilang dari daftar setelah
   reconciliation.
9. Expected: stock on-hand tetap sama; reservation saja yang dilepas.
10. Bila release atau refresh mengalami conflict, PWA menampilkan pesan lokal.
    Jika mutation sudah terjadi tetapi refresh gagal, cache harus berubah ke
    state diblokir, bukan mempertahankan angka lama.
11. Nonaktifkan kembali entitlement Offline setelah UAT bila gate checkout
    Offline belum dibuka.

## Compatibility dan rollback

- Online Draft/Post, Split Payment, Customer quick-create, receipt, dan Session
  tetap memakai execution path sebelumnya.
- IndexedDB v4 tidak berubah.
- Rollback UI cukup mengembalikan tiga file PWA di atas; tidak ada data/schema
  yang perlu dihapus.
- Allowance yang telanjur aktif harus dilepas melalui RPC/PWA atau force revoke
  melalui Backoffice, bukan direct table update/delete.

## Next safe step

Setelah Phase-19 Backoffice UAT dan Phase-20 PWA UAT lulus, buka desain sempit
Keranjang → retained Offline queue:

1. eligibility dan freshness gate sebelum transaksi boleh disimpan;
2. exact allowance validation per line;
3. Slip Offline yang jelas bukan invoice final;
4. queue list/status/retry/conflict UX;
5. network-loss dan reconnect UAT.

Jangan mengaktifkan penyerahan barang atau pembayaran Offline sebelum seluruh
gate tersebut terbukti.
