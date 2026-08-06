# KGS POS PWA

Status saat ini: **online POS + Sale Draft + Split Payment + Sales Return +
Expense online + Stock Request, Goods Receipt, dan Draft Retur Pembelian online** untuk G4/G5.
Daftar Draft per Store, heartbeat, takeover, force release, cancel, server
repricing, dan multi-metode exact-total sudah local-ready. Retained Offline Sale
queue dan authoritative catalog snapshot cache sudah tersedia di IndexedDB.
Keranjang dapat masuk ke queue saat koneksi terputus hanya bila exact-scope
snapshot valid, Product bukan Bundle, Payment eligible, dan allowance lokal
mencukupi. Exact-scope cold-start dan status-first reconnect sudah local-ready;
entitlement/policy tetap harus dibuka server-side.

## Menjalankan lokal

1. salin `.env.example` menjadi `.env`;
2. isi `VITE_SUPABASE_URL` dan anon/publishable key;
3. jalankan `npm install`;
4. jalankan `npm run dev`.

Untuk development di repository ini, bila nilai `.env` PWA masih placeholder,
Vite otomatis memakai `NEXT_PUBLIC_SUPABASE_URL` dan
`NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` dari `backoffice/.env.local`. Hanya dua
nilai publik tersebut yang diteruskan ke browser; service-role key tidak pernah
dibaca atau diekspos. Deployment PWA tetap wajib mengisi variable `VITE_*`
sendiri.

Jangan memasukkan service-role key ke PWA. Authentication memakai Supabase Auth
user dan seluruh query/RPC tetap melewati RLS serta active-company context.

## Flow aktif

1. Cashier login;
2. pilih Company aktif;
3. pilih Terminal POS dan Gudang penjualan;
4. masukkan modal kas fisik dan buka sesi;
5. pilih Product-UOM, Customer, Pricelist, diskon, rounding, dan satu atau
   beberapa Payment Method;
   untuk satu metode, bagian tagihan mengikuti total final otomatis. Cashier
   mengisi nominal Cash/Transfer yang diterima; bila lebih, POS meminta pilihan
   dikembalikan atau disimpan sebagai saldo Customer reguler yang eligible;
6. `Simpan Draft` memanggil `save_pos_sale_draft_with_pricelist`;
7. tombol `Draft` membuka daftar same-Store dan mengunci satu editor; saat
   dilanjutkan harga dihitung ulang dan payment wajib dikonfirmasi kembali;
8. `Konfirmasi & Post` menghitung ulang Draft dan memanggil
   `post_pos_sale_with_pricelist`;
9. shortage tetap menjadi Draft tanpa payment, movement, atau event final;
10. setelah `POSTED`, transaksi langsung direset sementara receipt tetap tampil;
11. struk membaca `receipt_snapshot` dan fallback browser membukanya pada tab
    cetak baru, bukan mengunduh file;
12. menu `Offline` pada header membuka drawer berisi scope
    Terminal/Gudang/Session, snapshot terakhir, usia cache, dan allowance lokal;
    snapshot pertama dicoba otomatis saat Session online terbuka;
    Cashier dapat meminta allowance sesi sendiri atau melepaskannya sebelum
    dipakai antrean tanpa mengambil ruang workspace;
13. tombol `Customer baru` pada bagian pelanggan membuat Customer sederhana
    melalui RPC guarded; Company selalu berasal dari active Company dan Customer
    baru langsung dipilih setelah katalog dimuat ulang;
14. saat koneksi putus, `Konfirmasi & Post` berubah menjadi `Simpan Offline`.
    PWA menghitung harga dari snapshot exact-scope, memvalidasi allowance base
    quantity dan Payment, lalu menyimpan payload/idempotency ke IndexedDB;
15. setelah local commit berhasil, keranjang direset dan Slip Offline dibuka.
    Slip diberi watermark `BELUM TERSINKRON — BUKAN INVOICE FINAL`;
16. drawer Offline menampilkan retained queue. Kasir dapat sinkronisasi/retry,
    memeriksa status ambigu, dan membuka invoice final setelah acknowledgement
    `POSTED`;
17. setelah satu snapshot online berhasil, reload tanpa jaringan memulihkan
    Company, Terminal, Gudang, Session, katalog, allowance, dan queue hanya
    untuk cached auth user yang sama;
18. saat reconnect, active Company diselaraskan dan record yang pernah menyentuh
    server diperiksa statusnya sebelum retry. State ambigu tidak diproses
    otomatis;
19. tombol `Return` membuka pencarian invoice posted pada Store aktif. Kasir
    memilih qty dan kondisi barang, cara refund Cash/Transfer, lalu menyimpan
    Draft. Nilai refund dihitung otomatis dari snapshot Sale asal dan posting
    tetap menunggu Store Manager/Admin;
20. bila entitlement Company aktif, tombol `Expense` memiliki tab `Ajukan` dan
    `Cairkan Tunai`. Pengajuan menghasilkan `SUBMITTED` atau auto-`APPROVED`.
    Tab pencairan hanya memuat dokumen Cash approved Store aktif; nominal dan
    metode read-only, kemudian RPC guarded mencatat satu Cash Drawer `OUT` pada
    sesi aktif. Transfer/non-tunai tetap dikonfirmasi Finance di Backoffice;
21. tab `Penyelesaian` menampilkan dana tambahan Cash yang sudah approved.
    Nominal/metode tidak dapat diedit dan pencairan guarded mengurangi expected
    cash sesi tepat sekali. Review serta pembayaran tambahan non-Cash dilakukan
    dari Backoffice;
22. tombol `Minta Stok` membuat kebutuhan barang tanpa memilih Supplier;
23. tombol `Terima Barang` menampilkan Supplier Order Store aktif yang masih
    dapat diterima. Kasir dapat menyimpan/resume/cancel Draft dan mencatat
    jumlah aktual serta rincian baik/rusak/ditolak;
24. `Post & Tambah Stok` memakai RPC canonical. Barang baik masuk Gudang tujuan,
    rusak ke Gudang `DAMAGED`, ditolak tidak masuk stok/AP, dan over-receipt
    diperbolehkan dengan warning.

Setiap bagian Split Payment mempunyai key stabil untuk retry, alokasi tagihan,
Cash tender/change, proof URL, dan estimasi fee. Satu metode mengikuti total
final otomatis; pada Split Payment Cashier membagi alokasi antar-metode. Total
alokasi wajib menutup total server. Uang Cash yang diterima boleh lebih besar
dari alokasi dan selisih dicatat sebagai kembalian. Fee persisted tetap dihitung
ulang oleh server dari snapshot Payment Method.

Harga yang tampil sebelum Draft hanya fallback Product-UOM. Total final dan
harga per line yang berlabel hasil server berasal dari resolver canonical.
Pricelist `Otomatis` mengikuti assignment Customer lalu Global default.
Override Cashier hanya menampilkan Pricelist eligible dan divalidasi ulang
server-side.

Layout operasional dirancang tablet-first: katalog dan checkout menjadi dua
panel pada lebar tablet, checkout sticky dengan scroll sendiri, touch target
minimum 44 px, dan kembali satu kolom pada layar kecil.

## Stress test checkout staging

`npm.cmd run stress:g4-checkout` menguji Post concurrent pada satu Draft
disposable. Command ini benar-benar mem-post transaksi serta mengurangi
stok/FIFO, sehingga hanya boleh dipakai di staging/development setelah membaca
`docs/runbooks/G4_PHASE10_TRUE_CONCURRENT_POST_STRESS.md`. Script memakai akun
biasa, Company aktif terakhir, dan nomor Draft user-facing; credential/token
tidak dicetak.

## Boundary

- Offline checkout fail-closed: tanpa entitlement, Terminal policy, snapshot,
  Customer/Pricelist/Payment reference, dan allowance cukup, pemeriksaan
  menampilkan alasan dan local commit ditolak. Bundle dan TEMPO belum boleh
  masuk queue.
- Endpoint `/api/pos/sync` mengembalikan `OFFLINE_SYNC_NOT_ENABLED` dan tidak
  menulis Sale.
- Queue canonical tidak menghapus payload setelah sync. Acknowledgement,
  submission ID, error, attempt, dan idempotency identity tetap tersimpan lokal.
- Catalog cache memvalidasi exact Session/Terminal/Gudang/Cashier scope,
  canonical payload hash, caller-defined freshness, dan explicit invalidation.
  Sisa allowance lokal dikurangi queue pada catalog version yang sama.
- Issue/release allowance Cashier hanya memakai guarded RPC. Jumlah dihitung
  server, force revoke tetap di Backoffice, dan cache di-invalidasi bila
  mutation berhasil tetapi reconciliation snapshot gagal.
- Cold-start hanya tersedia setelah operational scope dan snapshot authoritative
  tersimpan pada perangkat. Logout, close Session, identity mismatch, atau
  snapshot invalid memblokir restore; login/pembukaan Session pertama tetap
  memerlukan server.
- Customer Balance credit dari overpayment online sudah terhubung ke checkout;
  Customer Balance sebagai tender, refund-to-balance, offline balance, Ketul,
  dan Deposit lanjutan tetap menunggu gate roadmap
  masing-masing. Expense terbuka sampai initial disbursement online;
  penyelesaian membuka request biaya aktual, return Cash, dan request dana
  tambahan. Eksekusi tambahan online dibuka terpisah: Cash melalui Session POS,
  non-Cash melalui Backoffice. Offline Expense dan jurnal tetap tertutup. Sales Return sudah terbuka sampai required-approval/post boundary;
  split refund dan jurnal tetap tertutup.
- Quick-create Customer POS hanya membuka identitas dasar. Customer induk,
  kredit/termin, dan default Pricelist tetap dikelola dari Backoffice.
- Cashier biasa membutuhkan company membership dan assignment `CASHIER` aktif
  pada Store. Super Admin serta Company Owner/Admin memakai role inheritance
  yang disetujui. Store Manager dapat memakai POS hanya pada Store assignment
  aktifnya. Seluruhnya tetap membutuhkan Terminal aktif, Gudang
  `is_sale_source`, Payment Method eligible, dan sesi `OPEN`.
- Goods Receipt hanya online dan bersumber dari Supplier Order
  `CONFIRMED/PARTIALLY_RECEIVED` pada Store sesi. Supplier Invoice, matching,
  payment Supplier, Purchase Return, dan Journal final tetap tertutup.
- Stok minus Phase 61 hanya tersedia online untuk produk non-Bundle setelah
  entitlement, policy Company, Gudang, dan permission user lolos di server.
  Server meminta alasan melalui error contract; PWA menampilkannya pada modal
  custom dan menyimpan alasan ke payload Draft sebelum retry. Ineligible,
  over-limit, Offline, dan Bundle tetap Draft/fail-closed.
