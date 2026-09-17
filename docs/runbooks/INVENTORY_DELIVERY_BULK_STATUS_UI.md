# Inventory Delivery Bulk Status UI

## Status

Local client verification **PASS**. Fitur ini tidak menambah migration atau RPC.
Backoffice mengorkestrasi endpoint satuan POS atau Backoffice Sales yang sudah
live sesuai sumber Surat Jalan.
Deployment dan authenticated smoke tetap dilakukan manual.

## Impact map

- Direct: `DeliveryDocumentView` membuka checkbox Backoffice Sales, menyatukan
  aksi bulk menjadi satu tombol progresif, dan menyelaraskan label terminal
  menjadi **Diterima**.
- Downstream: POS tetap memakai endpoint Delivery POS; Backoffice Sales memakai
  endpoint `backoffice-delivery-orders` dengan aksi canonical `DISPATCH` atau
  `RECEIVE` serta tanggal aktif Company.
- Tidak berubah: schema, RPC, Reservation/FIFO/Movement/Finance writer,
  permission, optimistic version, Purchase, Invoice, Payment, dan data lama.
- Risiko yang dijaga: status campuran/partial/Pickup fail-closed; penerimaan
  bulk hanya clean receipt; kegagalan per dokumen tidak mengubah dokumen gagal.
- Belum dibuktikan lokal: authenticated browser mutation atas fixture nyata.
  Karena mutation memengaruhi Stock, verifikasi tersebut wajib di target UAT,
  bukan Production tanpa dokumen uji yang disetujui.

## Kontrak

- Checkbox existing dipakai bersama oleh bulk download dan bulk status.
- Tombol progresif menampilkan **Mulai pengiriman** hanya bila seluruh pilihan
  merupakan Delivery `READY`.
- Delivery linked mengirim seluruh sisa quantity melalui
  `dispatch_sales_delivery`; Delivery legacy tetap melalui compatibility runtime.
- Tombol yang sama berubah menjadi **Konfirmasi diterima** bila seluruh pilihan
  POS `DISPATCHED`, atau Backoffice Sales `IN_TRANSIT` dan `receiptReady`.
  Backoffice menerima tanpa selisih melalui aksi canonical `RECEIVE`; selisih
  wajib diproses dari detail.
- Pickup, status campuran, dan `PARTIALLY_DISPATCHED` fail-closed. Partial tetap
  dikerjakan dari detail per Surat Jalan.
- Maksimal mengikuti batas checkbox existing: 50 dokumen.
- Dokumen diproses berurutan. Hasil sukses/gagal ditampilkan per Surat Jalan;
  kegagalan satu row tidak mengembalikan efek row lain yang sudah berhasil.

Tidak ada direct table update. Permission, active Company, optimistic version,
Reservation, FIFO, Movement, negative-stock cost, serta Finance tetap divalidasi
oleh runtime canonical per dokumen.

## Rollout

1. Pastikan closing postflight ODR-6B.2 terakhir tetap seluruhnya `PASS`.
2. Deploy/restart Backoffice target, lalu hard refresh.
3. Jalankan smoke di bawah pada Company dummy dengan role pengelola Inventory.
4. Rerun closing postflight ODR-6B.2 setelah Dispatch dan Received.
5. Stop bila ada `FAIL`, `BLOCKER`, queue aktif, Finance exception terbuka, atau
   rekonsiliasi Reservation/Stock/FIFO/Movement tidak nol.

## Authenticated smoke

1. Buat dua Order Delivery baru dengan stok memadai dan konfirmasi keduanya.
2. Di Inventory -> Surat Jalan, centang kedua row `READY`.
3. Pastikan tombol progresif berubah menjadi **Mulai pengiriman**.
4. Buka konfirmasi tanpa mengeksekusi; cocokkan nomor, penerima, dan gudang.
5. Konfirmasi. Hasil kedua row harus `Berhasil · Dalam perjalanan`.
6. Cocokkan penurunan On Hand/FIFO/Movement dengan penurunan Reserved Out;
   Available tidak boleh berubah akibat pasangan tersebut.
7. Centang kedua row `DISPATCHED`/`IN_TRANSIT`, pastikan tombol berubah menjadi
   **Konfirmasi diterima**, lalu konfirmasi clean receipt.
8. Keduanya tampil **Diterima**; Stock/FIFO/Movement tidak berubah lagi.
9. Negative test: pilihan READY+DISPATCHED, Pickup, dan Partial membuat tombol
   bulk status disabled; tombol detail, print, download satuan, dan ZIP tetap ada.
10. Negative test optimistic lock: buka halaman pada dua tab, ubah satu SJ dari
    tab pertama, lalu bulk dari tab stale. Hanya row stale yang gagal dengan
    pesan muat ulang; row lain dan rekonsiliasi tetap benar.

## Rollback dan compatibility

Rollback cukup redeploy build Backoffice sebelumnya. Tidak ada schema, backfill,
atau data rollback. Operasi satuan, partial Dispatch, print, unduh PDF, ZIP,
Pickup, legacy Delivery, Purchasing, dan Finance writer tidak diubah.
