# Runbook G2 Fase 5 - Canonical Product API dan UI

**Scope:** Backoffice Product STOCK + Product-UOM canonical  
**Requirement:** MST-001, MST-002  
**Dependency:** migration G2 fase 4 `20260721210000` complete  
**Status:** COMPLETE - LOCAL BUILD PASS; PRODUCT FLOW ACCEPTED FOR CURRENT G2 STEP

## Perubahan

- Backoffice membaca Product, Category, dan seluruh Product-UOM dari active
  Company melalui route server authenticated.
- Create/update Product memakai RPC atomic `save_product_with_uoms`; browser
  tidak menulis langsung ke `products` atau `product_uoms`.
- Form mendukung Category, base UOM, UOM acuan berat, berat dalam kg, harga
  beli/jual per UOM, barcode, URL gambar eksternal, dan status Product.
- Base UOM dipilih sekali pada identitas Product dan ditampilkan terpisah dari
  daftar kemasan/UOM turunan.
- Baris turunan memakai format langsung `1 DUS = 10 KETUL`, diurutkan otomatis
  berdasarkan faktor, dan tetap disimpan langsung terhadap base UOM.
- UOM dengan faktor terbesar otomatis menjadi acuan berat; user tidak memilih
  radio base/acuan pada setiap baris.
- Saat kemasan lebih besar ditambahkan, UI menjadikannya satuan pembelian yang
  aktif secara awal. Default per Supplier tetap menjadi kontrak Product-Supplier
  pada fase Purchasing.
- Product baru pada fase ini selalu tipe `STOCK`; Bundle tetap ditahan sampai G3.
- Import Product legacy dihapus dari jalur UI aktif. Route compatibility lama
  belum dihapus, tetapi RPC database menolak eksekusi authenticated.
- POS, stock balance, Opening Stock, dan checkout tidak diubah pada fase ini.

## Evidence Otomatis

- `npm.cmd run lint`: PASS.
- `npm.cmd run build`: PASS.
- Build mengenali `/api/master/products` dan
  `/api/master/products/[id]` sebagai dynamic server routes.

## Langkah Smoke Lokal

1. Restart Backoffice lokal dan login sebagai Super Admin atau pengelola katalog.
2. Buka menu `Products & Stock`; pastikan daftar terbuka tanpa notifikasi error
   dan tombol import legacy sudah tidak ada.
3. Klik `Tambah Product` lalu buat satu Product STOCK dengan Category dan UOM
   yang memang akan digunakan. Jika baru ada satu UOM, pilih UOM yang sama untuk
   base dan acuan berat dengan faktor `1`.
4. Isi berat acuan lebih dari `0`, aktifkan fungsi beli/jual, dan isi harga
   keduanya. URL gambar boleh dikosongkan; jika diisi wajib URL `https://`.
5. Simpan dan pastikan Product muncul pada daftar.
6. Edit nama atau harga Product tersebut, simpan, lalu muat ulang dan pastikan
   perubahan bertahan tanpa notifikasi error.
7. Buka kembali menu Backoffice lain dan POS untuk smoke kompatibilitas saja.

## Stop Condition

- Jika daftar Product gagal dimuat, kirim response/error route yang tampil dan
  jangan membuat Product lewat SQL atau table editor.
- Jika create/update gagal, jangan memakai import legacy sebagai jalan pintas.
- Jangan membuat Opening Stock, Stock Movement, atau transaksi POS pada fase
  smoke ini.
- Jangan membuat Bundle; komposisi dan stock posting Bundle masih deferred ke G3.

## Sisa G2

- lifecycle Product-UOM yang lebih eksplisit pada UI;
- generic import/export staging, dry-run, partial result, dan history;
- master Supplier, Customer, Pricelist, Payment Method, Transaction Category,
  Tax, serta minimum COA sesuai G2 exit criteria;
- cache/version payload dan penutupan dependency free-text sebelum G2 exit;
- Vercel Preview baru disiapkan setelah seluruh G2 exit criteria lulus.
