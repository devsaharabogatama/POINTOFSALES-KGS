# G4 Phase 22 — Offline Checkout Queue PWA UI

## Status

`LOCAL-READY`, menunggu authenticated tablet/UAT dengan disposable scope.
Tidak ada migration database baru pada Phase ini.

## Yang Dibuka

- koneksi putus setelah Cashier Session dan snapshot authoritative tersedia;
- PWA mencoba menyiapkan snapshot authoritative otomatis ketika Session online
  terbuka; tombol refresh tetap tersedia untuk retry;
- Cart dihitung dari snapshot Product-UOM/Pricelist exact-scope;
- quantity dikonversi ke Base UOM dan harus ditutup allowance lokal;
- Payment Method harus ada pada snapshot; total bagian harus exact;
- payload, hash, catalog version, client transaction ID, dan idempotency key
  disimpan retained di Dexie;
- local commit sukses mereset Cart dan menghasilkan Slip Offline dengan watermark
  `BELUM TERSINKRON — BUKAN INVOICE FINAL`;
- drawer Offline menyediakan retained status, retry/process, status check untuk
  state ambigu, dan pembukaan invoice final setelah `POSTED`.

## Fail-Closed Boundary

- Company, Store, Terminal, Gudang, Session, dan Cashier harus sama persis
  dengan snapshot;
- entitlement/policy/Terminal tetap ditentukan server;
- cache invalid/missing, Product Bundle, TEMPO, Payment tidak eligible, stale
  master reference, atau allowance kurang menolak local queue;
- client tidak menulis Sale, Payment, Stock, FIFO, Movement, atau allowance
  secara langsung;
- sync tetap melalui `submit_pos_offline_sale`,
  `process_pos_offline_sale_submission`, dan
  `get_pos_offline_submission_status`;
- acknowledgement/payload local tidak dihapus setelah `POSTED`;
- cold-start penuh tanpa network masih deferred. Scope Phase 22 adalah koneksi
  terputus setelah aplikasi, Session, dan snapshot sudah aktif.

## Local Evidence

Jalankan dari `pwa`:

```powershell
npm.cmd run lint
npm.cmd run build
```

Expected: keduanya exit `0`. Warning chunk Vite di atas 500 kB bersifat
non-blocking dan tidak mengubah server authority.

## Manual UAT

Gunakan Company/Terminal disposable:

1. aktifkan entitlement Offline dan policy Terminal sesuai runbook Phase 17;
2. login Kasir dan buka sesi; pastikan drawer menyatakan snapshot disiapkan
   otomatis, lalu minta allowance Product. Jika bootstrap gagal, tekan
   `Perbarui snapshot`;
3. tambahkan Product non-Bundle dengan quantity di bawah allowance;
4. pilih Customer/Pricelist dan Payment eligible;
5. putuskan koneksi browser;
6. pastikan total berubah ke harga `snapshot Offline` dan tombol menjadi
   `Simpan Offline`;
7. konfirmasi melalui modal custom; pastikan Cart reset dan Slip Offline
   ber-watermark tampil;
8. buka menu Offline: record harus `PENDING SYNC` dan allowance lokal berkurang;
9. sambungkan koneksi, tekan `Sinkronkan`;
10. expected `POSTED`, invoice final dapat dibuka, dan snapshot/allowance
    direkonsiliasi;
11. ulangi dengan allowance kurang, Bundle, TEMPO, Payment tidak eligible, dan
    scope cache salah; seluruhnya harus ditolak sebelum local commit;
12. tutup modal/drawer dengan `Escape`.

Pada pembayaran tunggal, bagian tagihan terisi otomatis dari total final.
Untuk Cash, uji `Uang diterima` lebih besar daripada bagian tagihan; expected
Post berhasil dan selisih tampil sebagai kembalian. Jangan menambah kelebihan
ke field alokasi tagihan. Penyimpanan kembalian sebagai Customer Balance masih
menunggu gate ledger/entitlement Customer Balance.

## Compatibility

- Online Draft/Post, Split Payment, receipt final, quick Customer, dan Draft
  edit-lock tidak berubah.
- Tidak ada schema/data backfill atau perubahan grant.
- Slip Offline bukan invoice dan tidak memakai nomor invoice server.

## Next Safe Step

Setelah UAT Phase 20 dan Phase 22 sukses, lanjutkan roadmap ke cold-start
bootstrap/restore dan controlled offline conflict/recovery stress. Jangan
membuka Return, Customer Balance, TEMPO Offline, Expense, atau Deposit dari
Phase ini.
