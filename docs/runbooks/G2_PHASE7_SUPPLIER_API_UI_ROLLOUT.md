# Runbook G2 Fase 7 - Supplier API dan UI Backoffice

**Scope:** Backoffice Supplier dan relasi Supplier-Product-UOM pembelian  
**Dependency:** migration `20260721230000` serta postflight/behavioral test complete  
**Status:** COMPLETE

User mengonfirmasi flow Supplier aman pada 21 Juli 2026. Revisi UX lanjutan
menampilkan nama UOM (contoh `Dus`, `Ketul`) sebagai label operasional; kode
internal UOM tidak lagi menjadi label utama pada form Product/Supplier.

## Implementasi

- menu top-level `Supplier` pada Backoffice;
- tab `Daftar Supplier` untuk identitas, kontak, NPWP, termin, rekening referensi,
  status, dan optimistic version;
- tab `Supplier per Product` untuk Product, Supplier, Product-UOM pembelian, kode
  Product vendor, harga referensi, preferred Supplier, dan status;
- UOM pembelian terbesar ditampilkan lebih dulu dan hanya UOM yang aktif serta
  diizinkan untuk pembelian yang dapat dipilih;
- `last_purchase_price` hanya ditampilkan read-only dan belum diisi manual;
- seluruh create/update memakai RPC `save_supplier` atau
  `save_product_supplier`; direct table mutation tetap tertutup;
- role tombol mengikuti kontrak RPC: Finance/Accounting dapat mengelola identitas
  Supplier, sedangkan Product-Supplier untuk pengelola katalog/gudang;
- tidak ada perubahan pada Purchase, penerimaan barang, AP, atau stok.

## Evidence Lokal

- `npm.cmd run lint`: PASS;
- `npm.cmd run build`: PASS;
- Next.js build mengenali empat dynamic route baru:
  `/api/master/suppliers`, `/api/master/suppliers/[id]`,
  `/api/master/product-suppliers`, dan `/api/master/product-suppliers/[id]`.

## Smoke Test Manual

1. Restart Backoffice dan login pada Company yang sudah mempunyai Product serta
   UOM pembelian aktif.
2. Buka menu `Supplier`; pastikan dua tab terbuka tanpa notifikasi error.
3. Buat satu Supplier aktif dengan kode/nama wajib; kosongkan field opsional dan
   pastikan tetap tersimpan.
4. Edit kontak, termin, atau rekening Supplier lalu simpan dan reload.
5. Pada `Supplier per Product`, hubungkan Supplier ke Product dan pilih UOM beli
   terbesar (contoh `DUS`, bukan base `KETUL`).
6. Isi harga beli referensi dan tandai Supplier utama; simpan lalu reload.
7. Edit relasi dan pastikan harga beli terakhir tetap read-only (`-` selama belum
   ada dokumen pembelian tervalidasi).
8. Pastikan menu Product, Master Data, Customer, Finance, Tim, dan POS existing
   tetap dapat dibuka.

## Expected

- create/edit Supplier dan relasi berhasil tanpa direct table grant;
- satu Product tidak dapat mempunyai dua Supplier aktif yang sama-sama preferred;
- Product/Supplier/UOM lintas Company ditolak oleh RPC;
- tidak ada perubahan quantity stock atau jurnal dari smoke test ini.

## Stop Condition

- Jika menu menampilkan `FORBIDDEN`, kirim role akun dan error persis; jangan
  membuka RLS atau direct table grant.
- Jika muncul `PREFERRED_SUPPLIER_ALREADY_EXISTS`, nonaktifkan preferred pada
  relasi lama sebelum menetapkan relasi baru.
- Jika UOM pembelian tidak muncul, periksa Product-UOM: harus aktif dan opsi
  pembeliannya dicentang; jangan mengubah database manual untuk melewati guard.
- Jangan lanjut ke Supplier Order atau Goods Receipt sebelum smoke test ini
  dikonfirmasi.
