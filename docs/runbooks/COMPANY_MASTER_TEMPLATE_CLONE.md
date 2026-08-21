# Duplikasi Template Master Antar-Company

Runbook ini dipakai untuk menyiapkan Company baru dari Company sumber tanpa
menyalin transaksi, saldo, stok, user, Customer, atau Supplier.

## Cakupan yang disalin

- Chart of Accounts dan konfigurasi posting Finance melalui operasi Finance
  yang sudah tersedia;
- Kategori Produk;
- UOM;
- Tax Rule beserta versi aktif dan pemetaan akun pajaknya;
- Product beserta base UOM, UOM turunan, harga beli/jual, barcode, bobot,
  gambar berbentuk referensi URL, serta assignment pajak;
- komposisi Bundle;
- Pricelist `GLOBAL` beserta rule yang tidak terikat Store tertentu.

## Yang tidak disalin

- stok, FIFO, Opening Stock, Stock Movement, minimum stock, dan izin stok minus;
- seluruh transaksi Penjualan, Pembelian, Expense, Finance Event, dan Journal;
- Customer, saldo Customer, serta Pricelist `CUSTOMER`;
- Supplier dan relasi Product-Supplier;
- Store, Warehouse, Terminal, sesi kasir, user, membership, role, permission,
  feature entitlement, dan policy operasional;
- binary logo/gambar. Nilai HTTPS `image_url` Product hanya direferensikan
  ulang; file pada storage tidak digandakan.

## Urutan aman

1. Buat Company tujuan dari Backoffice.
2. Jangan membuat transaksi, Opening Stock, atau Stock Movement pada Company
   tujuan.
3. Jalankan PREVIEW lalu APPLY Finance sesuai
   [COMPANY_FINANCE_CONFIGURATION_CLONE.md](COMPANY_FINANCE_CONFIGURATION_CLONE.md).
4. Isi empat nilai pada bagian `kgs_master_clone_config` di
   `supabase/diagnostics/company_master_template_clone_preflight.sql`:
   UUID dan nama persis Company sumber serta tujuan.
5. Jalankan seluruh file preflight dalam satu query SQL Editor.
6. Jangan lanjut jika ada `BLOCKER`. Status `REVIEW` harus diperiksa terhadap
   baseline otomatis Company baru.
7. Buka `supabase/operations/clone_company_product_master.sql`, isi UUID dan
   exact Company name yang sama. Biarkan `execute_clone=FALSE`, lalu jalankan
   seluruh file dan pastikan tidak ada `BLOCKER`.
8. Ubah hanya `execute_clone=TRUE` dan `confirmation` menjadi
   `CLONE_PRODUCT_MASTER`, kemudian jalankan seluruh file sekali lagi.
9. Hasil harus memuat `clone_result=APPLIED`. Verifikasi jumlah yang diharapkan:
   1 Category, 2 UOM, 61 Product, dan 119 Product-UOM untuk snapshot sumber
   yang dilaporkan pada 21 Agustus 2026.
10. Isi empat identitas Company pada
   `supabase/diagnostics/company_product_master_clone_postflight.sql`, jalankan,
   dan pastikan seluruh hasil `PASS`.
11. Setelah APPLY, konfigurasi Store, Warehouse, Terminal, user, permission,
   entitlement, stok awal, Customer, dan Supplier secara terpisah.

## Perlindungan APPLY

Pembuatan Company otomatis membuat Pricelist default. Operasi mempertahankan
identity Pricelist target dan mencocokkannya dengan normalized code, sehingga
tidak membuat dua default Pricelist. Seluruh ID Category, UOM, Tax, Product,
Product-UOM, dan Bundle dibuat ulang lalu diremap. Verifikasi jumlah, dependency,
dan zero-stock dijalankan sebelum statement selesai; kegagalan me-rollback
seluruh write atomik.

## Gate wajib

- `target_operational_history` harus `PASS`;
- `target_product_master_state` harus `PASS`;
- `source_product_dependency_integrity` harus `PASS`;
- `source_bundle_dependency_integrity` harus `PASS`;
- `source_tax_account_target_mapping` harus `PASS` setelah clone Finance;
- `source_store_scoped_global_pricelist` harus `PASS`;
- `master_identity_conflicts` harus `PASS`.

Preflight bersifat SELECT-only terhadap schema persisten. Hanya tabel temporary
session yang dibuat untuk menyimpan konfigurasi pemeriksaan.
