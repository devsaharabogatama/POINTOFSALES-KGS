# Import Pricelist Distributor per Company

Status: local-ready; migration database dan smoke pengguna masih manual.

## Hasil yang Dibangun

- File `.xlsx` atau `.csv` dicocokkan berdasarkan **Company aktif + SKU**.
- `COGS` dan `Retail` pada file dianggap harga per PACK.
- Harga Product-UOM aktif dihitung dengan rumus
  `harga target = harga PACK / faktor PACK × factor_to_base UOM target`.
- `Agen/SM`, `Spesial`, dan `Khusus` menjadi Pricelist reusable scope Customer.
- `Min 60/100/150 Pack` menjadi tier Pricelist Global default dengan basis
  `BASE_UOM_EQUIVALENT`, sehingga pembelian DUS tetap dihitung dalam PACK.
- Baris harga opsional yang kosong dilewati. COGS dan Retail wajib terisi.
- Preview tidak menulis database. Apply atomik, audited, tenant-scoped, dan
  exact retry tidak membuat rule ganda.

Import tidak mengubah Customer assignment, stok, FIFO, transaksi, invoice,
pembayaran, Financial Event, atau jurnal.

## Urutan Rollout

1. Jalankan [migration dasar](../../supabase/migrations/20260824100000_distributor_pricelist_import.sql)
   hanya bila versi tersebut belum pernah dipasang.
2. Jalankan [forward-fix SKU dilewati](../../supabase/migrations/20260824110000_distributor_pricelist_missing_sku_skip.sql).
3. Jalankan [postflight SELECT-only](../../supabase/diagnostics/distributor_pricelist_import_postflight.sql).
4. Semua hasil selain `INFO` wajib `PASS`.
5. Jalankan [behavioral test rollback-safe](../../supabase/tests/distributor_pricelist_import_behavior.sql).
6. Pastikan output terakhir `PASS` dan tidak ada exception.
7. Deploy Backoffice ke environment dengan migration tersebut.
8. Lakukan smoke menggunakan satu Company dan satu file kecil lebih dahulu.

## Cara Memasukkan File

1. Masuk Backoffice dan pilih Company target.
2. Buka **Data Exchange → Import → Pricelist**.
3. Upload file Excel tanpa mengubah header `Kode Produk`, `Nama Produk`,
   `COGS`, `Retail`, `Agen/SM`, `Spesial`, `Khusus`, `Min 60 Pack`,
   `Min 100 Pack`, dan `Min 150 Pack`.
4. Periksa preview. SKU yang tidak ditemukan ditandai **Dilewati** dan tidak
   memblokir SKU valid lainnya. Jika tidak ada satu pun SKU yang cocok, Apply
   tetap diblokir. Product yang ditemukan tetapi tidak mempunyai UOM jual PACK
   menjadi error dan memblokir Apply.
   Lebih dari satu UOM jual PACK pada Product, Pricelist target yang nonaktif,
   atau nama Pricelist target yang terduplikasi juga wajib diperbaiki dahulu.
5. Peringatan UOM DUS tidak ditemukan tidak memblokir import; harga UOM aktif
   lainnya tetap dihitung berdasarkan faktor masing-masing.
6. Centang konfirmasi lalu klik **Simpan ke [nama Company]**.
7. Untuk PT lain, pindahkan Company aktif lalu upload file yang sama kembali.
8. Periksa **Sales → Pricelist**. Hubungkan Customer ke `Harga Agen / SM`,
   `Harga Spesial`, atau `Harga Khusus` bila diperlukan.

Menu import hanya tersedia bagi user yang memiliki capability `IMPORT` untuk
Pricelist dan Product sekaligus. Pembatasan salah satunya harus menyembunyikan
aksi import dan tetap ditolak ulang oleh API/RPC.

## Pemeriksaan Smoke

- COGS `14629.5569236366` tersimpan sebagai `14629.5569`.
- Harga PACK sama dengan file.
- Harga DUS sama dengan harga PACK dikali isi PACK dalam DUS.
- Dua DUS berisi 30 PACK memenuhi tier minimum 60 PACK.
- SKU Company lain tidak berubah.
- Retry request yang sama tidak menggandakan rule.

## Forward-fix

Tidak ada rollback destruktif karena harga baru dapat segera menjadi snapshot
transaksi. Jika file salah, perbaiki file lalu import kembali pada Company yang
sama. Transaksi POSTED tetap memakai snapshot lamanya.
