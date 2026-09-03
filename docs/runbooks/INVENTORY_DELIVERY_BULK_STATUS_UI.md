# Inventory Delivery Bulk Status UI

## Status

Local client verification **PASS**. Fitur ini tidak menambah migration atau RPC.
Backoffice mengorkestrasi endpoint satuan Inventory Delivery yang sudah live.
Deployment dan authenticated smoke tetap dilakukan manual.

## Kontrak

- Checkbox existing dipakai bersama oleh bulk download dan bulk status.
- `Kirim terpilih` hanya aktif bila seluruh pilihan merupakan Delivery `READY`.
- Delivery linked mengirim seluruh sisa quantity melalui
  `dispatch_sales_delivery`; Delivery legacy tetap melalui compatibility runtime.
- `Tandai terkirim` hanya aktif bila seluruh pilihan merupakan Delivery
  `DISPATCHED` dan memakai `confirm_sales_delivery_received` untuk linked row.
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
3. Pastikan tombol **Kirim terpilih** aktif dan **Tandai terkirim** tidak aktif.
4. Buka konfirmasi tanpa mengeksekusi; cocokkan nomor, penerima, dan gudang.
5. Konfirmasi. Hasil kedua row harus `Berhasil · Dalam perjalanan`.
6. Cocokkan penurunan On Hand/FIFO/Movement dengan penurunan Reserved Out;
   Available tidak boleh berubah akibat pasangan tersebut.
7. Centang kedua row `DISPATCHED`, pilih **Tandai terkirim**, lalu konfirmasi.
8. Keduanya menjadi `DELIVERED`; Stock/FIFO/Movement tidak berubah lagi.
9. Negative test: pilihan READY+DISPATCHED, Pickup, dan Partial membuat tombol
   bulk status disabled; tombol detail, print, download satuan, dan ZIP tetap ada.
10. Negative test optimistic lock: buka halaman pada dua tab, ubah satu SJ dari
    tab pertama, lalu bulk dari tab stale. Hanya row stale yang gagal dengan
    pesan muat ulang; row lain dan rekonsiliasi tetap benar.

## Rollback dan compatibility

Rollback cukup redeploy build Backoffice sebelumnya. Tidak ada schema, backfill,
atau data rollback. Operasi satuan, partial Dispatch, print, unduh PDF, ZIP,
Pickup, legacy Delivery, POS, Purchasing, dan Finance tidak diubah.
