# G4 Phase 28 — Sales Return Backoffice Approval UI

## Status

`READY FOR AUTHENTICATED ROLE SMOKE`

Tidak ada migration baru pada fase ini. Database Sales Return Phase 26 dan PWA
Draft Return Phase 27 sudah tersedia. Fase ini hanya membuka jalur review,
posting, dan pembatalan Draft melalui RPC canonical yang sudah dijaga server.

## Scope

- menu `Sales > Approval Return` untuk `COMPANY_OWNER`, `COMPANY_ADMIN`, dan
  `STORE_MANAGER`;
- list/filter/search berdasarkan status, nomor Return, invoice asal, Customer,
  dan Store;
- detail user-facing tanpa UUID: Product/UOM, quantity, kondisi, Gudang tujuan,
  refund, creator, serta Cashier Session pelaksana;
- guarded posting melalui `post_sales_return` dengan optimistic version dan
  idempotency key;
- guarded cancel melalui `cancel_sales_return_draft` dengan alasan wajib;
- konfirmasi custom dan Escape-to-close; tidak memakai dialog bawaan browser.

## Invariant yang tetap berlaku

- browser tidak menulis langsung tabel Return, stok, FIFO, Movement, Payment,
  atau Financial Event;
- Store Manager hanya dapat memproses dokumen pada Store yang masuk cakupannya;
- Company Owner/Admin tetap dibatasi active Company;
- Return hanya dapat diposting saat Cashier Session pelaksana masih `OPEN`;
- satu posting mengikat refund, restorasi stok/FIFO sesuai kondisi, Movement,
  Cashier Session expected cash, audit, dan Financial Event secara atomic;
- Financial Event tetap `HOLD`; jurnal G6 belum dibuka;
- approval `OPTIONAL`, posting Kasir, split refund, Customer Balance, Offline
  Return, Credit Note, dan laporan Return tetap deferred.

## Evidence lokal

- `npm.cmd run lint` pada `backoffice`: PASS;
- `npm.cmd run build` pada `backoffice`: PASS;
- route build terdeteksi: list, post, dan cancel Sales Return.

## Authenticated smoke wajib

1. Pastikan ada Draft Return `RET-*` dari PWA dan Cashier Session pembuatnya
   masih `OPEN`.
2. Restart Backoffice atau hard refresh, lalu login sebagai Store Manager atau
   Company Admin pada Company yang sama.
3. Buka `Sales > Approval Return`; Draft harus muncul tanpa UUID teknis.
4. Buka detail dan cocokkan invoice asal, Customer, Store, Product/UOM,
   quantity, kondisi, Gudang tujuan, total, dan metode refund.
5. Buat Draft disposable kedua. Batalkan salah satunya dengan alasan; status
   harus `Dibatalkan` dan tidak boleh mengubah stok, FIFO, Movement, atau kas.
6. Pada Draft lain, centang konfirmasi lalu `Setujui & Posting`. Status harus
   menjadi `Sudah diposting`.
7. Verifikasi hasil sesuai kondisi barang: layak jual kembali menambah stok
   Gudang tujuan; rusak masuk Gudang Rusak; disposal tidak menambah stok.
8. Refund Cash harus mengurangi expected cash Session tepat sebesar refund.
   Refund Transfer harus mempertahankan tujuan/reference/proof snapshot.
9. Refresh dokumen final; UI tidak menawarkan posting ulang dan tidak boleh ada
   efek final ganda.
10. Uji role di luar approver atau Store lain: menu/data/mutation harus tidak
    tersedia atau ditolak server.

## Compatibility dan forward note

PWA Draft Return tidak diubah. Endpoint memakai Supabase session pengguna dan
active Company context, bukan service role. Bila Cashier Session sudah ditutup,
posting sengaja diblokir oleh kontrak Phase 26; jangan mengakali guard dari UI.

Setelah smoke ini PASS, lanjutkan roadmap G4. Jangan langsung membuka Finance
posting atau G5 Purchasing.
