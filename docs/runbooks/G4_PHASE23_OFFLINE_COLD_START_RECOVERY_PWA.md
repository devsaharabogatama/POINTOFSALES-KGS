# G4 Phase 23 — Offline Cold-Start and Recovery PWA

**Status:** LOCAL-READY — menunggu authenticated tablet UAT

Tidak ada migration atau perubahan grant pada fase ini. Database contract
Phase 11/12/14 tetap menjadi server authority.

## Yang Dibuka

- Dexie v5 menyimpan satu operational scope setelah snapshot authoritative
  berhasil: Company, Store, Terminal, Gudang, Cashier Session, dan Cashier;
- reload atau pembukaan ulang PWA tanpa jaringan memulihkan scope, katalog,
  Payment Method, Customer, Pricelist, allowance, dan retained queue;
- restore hanya menerima Supabase cached Session dengan `user.id` yang sama
  dengan `cashierId` snapshot;
- seluruh identity scope harus cocok dengan snapshot; cache invalid atau scope
  berbeda tetap fail-closed;
- reconnect menetapkan active Company server terlebih dahulu, memeriksa status
  submission yang pernah menyentuh server, lalu mengambil snapshot baru;
- `SYNCING` dan `NEEDS_CONFIRMATION` hanya menyediakan pemeriksaan status;
  `FAILED` dapat dicoba ulang secara manual; `POSTED` dan `INVALIDATED`
  terminal;
- crash lokal sesudah state `SUBMITTING` tetapi sebelum server menerima
  submission dipulihkan ke `PENDING_SYNC` hanya setelah server menyatakan
  submission tidak ditemukan.

## Boundary

- login pertama, pembukaan Session pertama, entitlement, Terminal policy, dan
  issuance allowance tetap memerlukan server;
- cold-start tidak menghidupkan Session yang sudah ditutup;
- logout dan close Session menginvalidasi snapshot serta menghapus operational
  scope lokal;
- reconnect tidak melakukan auto-retry transaksi `FAILED` atau
  `NEEDS_CONFIRMATION`;
- client tetap tidak menulis Sale, Payment, Stock, FIFO, Movement, allowance,
  atau Finance row secara langsung;
- Bundle, TEMPO Offline, Customer Balance, Return, Purchase, Expense, dan
  Deposit tetap deferred.

## Local Evidence

Dari folder `pwa`:

```powershell
npm.cmd run lint
npm.cmd run build
```

Expected exit `0`. Build harus menghasilkan service worker dan chunk
`offlineBootstrap`.

## Authenticated Cold-Start UAT

Gunakan scope disposable dan jangan logout/menutup Session di tengah happy path:

1. online, login Kasir, buka Session, dan buka menu `Offline`;
2. tekan `Perbarui snapshot` sekali pada build Phase 23 agar operational scope
   Dexie v5 tersimpan;
3. issue allowance Product dan pastikan drawer menampilkan cache serta jumlah
   tersedia;
4. simpan satu transaksi Offline atau sisakan queue existing;
5. tutup tab/PWA tanpa menekan `Keluar` dan tanpa menutup Session;
6. matikan jaringan, lalu buka ulang installed PWA atau reload;
7. expected Company, Terminal, Gudang, Session, katalog, allowance, dan queue
   kembali; status header `Offline · cache tersedia`;
8. buat satu local transaction lagi dan pastikan Slip Offline serta pengurangan
   allowance lokal tetap bekerja;
9. tutup dan buka PWA sekali lagi saat tetap offline; kedua queue harus tetap
   ada;
10. nyalakan jaringan; expected active Company direkonsiliasi, status submission
    diperiksa, lalu snapshot diperbarui;
11. `SYNCING`/`NEEDS_CONFIRMATION` hanya boleh `Periksa status`; `FAILED`
    memakai `Periksa & coba lagi`; jangan melihat retry otomatis;
12. sinkronkan record eligible sampai `POSTED`, buka invoice final, dan pastikan
    retained acknowledgement tidak terhapus.

## Negative UAT

1. saat online tekan `Keluar`, lalu matikan jaringan dan buka ulang: operational
   scope lama tidak boleh dipulihkan;
2. buka Session baru, siapkan snapshot, lalu tutup Session secara resmi; reload
   offline harus diblokir;
3. masuk dengan user berbeda pada perangkat yang sama: snapshot user pertama
   tidak boleh dipakai;
4. hapus/korup snapshot melalui DevTools hanya pada fixture disposable:
   integrity check harus memblokir cache, bukan membuka checkout;
5. putuskan jaringan saat submit; setelah reconnect, status server harus
   diperiksa sebelum tombol retry dapat menghasilkan final effect.

## Closing Evidence

Setelah UAT:

1. jalankan ulang Phase-23 preflight;
2. jalankan Phase-12 postflight;
3. expected seluruh invariant dan rekonsiliasi `PASS`;
4. simpan bukti status queue lokal dan satu invoice final tanpa payload sensitif.

## Next Safe Step

Setelah authenticated cold-start dan negative UAT lulus, lanjutkan controlled
disconnect/reconnect stress pada beberapa titik submit/process/status. Jangan
membuka modul deferred dari fase ini.
