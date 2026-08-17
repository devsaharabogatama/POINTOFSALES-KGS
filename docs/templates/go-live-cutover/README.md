# Paket Template Cutover Go-Live KGS POS

Paket ini dipakai untuk menyiapkan data awal Company sebelum transaksi go-live.
Semua file adalah CSV UTF-8 dengan pemisah koma. Jangan mengubah nama header.

## Arti status

- **IMPORT AKTIF**: dapat diunggah sekarang melalui Backoffice > Import & Export.
- **FORM MANUAL**: lembar kerja persiapan; input melalui menu Backoffice yang disebutkan.
- **WORKFLOW KHUSUS**: bukan generic import; harus dibuat sebagai Draft dan diposting oleh role berwenang.
- **MENUNGGU RUNTIME**: template sudah disiapkan, tetapi belum boleh dimasukkan ke database karena workflow opening subledger/Finance belum tersedia.
- **KONTROL**: tidak diimport; dipakai untuk rekonsiliasi.

## Cut-off yang dipakai

Pilih satu tanggal cut-off, disarankan akhir bulan. Jika operasi mulai pada
`2026-09-01`, gunakan `effective_date=2026-08-31`. Bekukan input manual setelah
cut-off, lalu gunakan sumber data yang sama untuk seluruh template.

## Urutan wajib

| Urutan | File | Status | Cara masuk |
|---:|---|---|---|
| 00 | `00_cutover_control.csv` | KONTROL | Isi total pembanding dari pembukuan manual |
| 01 | `01_company_setup.csv` | FORM MANUAL | Pengaturan Company, branding, feature, timezone |
| 02 | `02_store_terminal_setup.csv` | FORM MANUAL | Master Toko, Terminal POS, Gudang sumber jual |
| 03 | `03_uom.csv` | IMPORT AKTIF | Tipe `UOM` |
| 04 | `04_product_category.csv` | IMPORT AKTIF | Tipe `PRODUCT_CATEGORY` |
| 05 | `05_warehouse.csv` | IMPORT AKTIF | Tipe `WAREHOUSE`; Toko harus sudah ada |
| 06 | `06_supplier.csv` | IMPORT AKTIF | Tipe `SUPPLIER` |
| 07 | `07_customer_category.csv` | IMPORT AKTIF | Tipe `CUSTOMER_CATEGORY` |
| 08 | `08_chart_of_account.csv` | IMPORT AKTIF | Tipe `CHART_OF_ACCOUNT`; induk sebelum anak |
| 09 | `09_transaction_category.csv` | IMPORT AKTIF | Tipe `TRANSACTION_CATEGORY`; biasanya cukup bawaan sistem |
| 10 | `10_tax_rule.csv` | FORM MANUAL | Master Pajak; selesai sebelum Produk |
| 11 | `11_product.csv` | IMPORT AKTIF | Tipe `PRODUCT`; satu baris per UOM |
| 12 | `12_product_supplier.csv` | IMPORT AKTIF | Tipe `PRODUCT_SUPPLIER` |
| 13 | `13_minimum_stock.csv` | IMPORT AKTIF | Tipe `PRODUCT_WAREHOUSE_MINIMUM_STOCK` |
| 14 | `14_customer.csv` | FORM MANUAL | Master Customer; jangan membuat Walk-In |
| 15 | `15_pricelist.csv` | FORM MANUAL | Master Pricelist dan rule Product-UOM |
| 16 | `16_payment_method.csv` | FORM MANUAL | Metode bayar dan scope Toko |
| 17 | `17_finance_account_mapping.csv` | FORM MANUAL | Mapping fungsi akun/rule Finance |
| 18 | `18_bundle.csv` | FORM MANUAL | Bundle header dan sales UOM |
| 19 | `19_bundle_component.csv` | FORM MANUAL | Komposisi Bundle; seluruh Product harus sudah ada |
| 20 | `20_opening_stock.csv` | WORKFLOW KHUSUS | Inventory > Stok Awal; satu Draft per Gudang/tanggal |
| 21 | `21_opening_receivable.csv` | MENUNGGU RUNTIME | Piutang invoice terbuka; jangan dibuat sebagai Sale palsu |
| 22 | `22_opening_payable.csv` | MENUNGGU RUNTIME | Utang invoice terbuka; jangan dibuat sebagai Goods Receipt/Faktur palsu |
| 23 | `23_opening_customer_deposit.csv` | MENUNGGU RUNTIME | Deposit/saldo Customer, bukan piutang |
| 24 | `24_opening_gl.csv` | MENUNGGU RUNTIME | Saldo akun non-subledger dan penutup Clearing |
| 25 | `25_reconciliation_control.csv` | KONTROL | Hasil pembandingan setelah seluruh posting |

## Cara memakai file IMPORT AKTIF

1. Login Backoffice dan pilih Company tujuan.
2. Buka **Import & Export** lalu pilih **Import**.
3. Pilih tipe persis seperti tabel di atas.
4. Gunakan mode referensi **Nama** untuk create awal.
5. Upload CSV, lakukan mapping, validasi, dan preview.
6. Perbaiki semua error. Jangan commit selama masih ada referensi ambigu.
7. Gunakan `CREATE_ONLY` untuk muatan pertama.
8. Commit, lalu export hasil master sebagai arsip ID/version sebelum lanjut.

Boolean menggunakan `true` atau `false`. Tanggal menggunakan `YYYY-MM-DD` dan
timestamp menggunakan ISO-8601. Angka tidak memakai pemisah ribuan; gunakan
`125000`, bukan `125.000` atau `Rp125.000`.

## Aturan saldo awal

1. Posting `20_opening_stock.csv` lebih dahulu melalui workflow Stok Awal.
   Quantity selalu dalam Base UOM dan biaya adalah HPP per Base UOM.
2. Setiap pasangan Product-Gudang hanya boleh menerima Stok Awal sebelum pernah
   mempunyai Movement. Jika sudah ada Movement, gunakan Adjustment resmi.
3. Stok Awal membuat Debit Persediaan dan Kredit Opening Balance Clearing.
4. Jangan memasukkan nilai persediaan lagi ke `24_opening_gl.csv`; saldo akun
   Opening Balance Clearing dipakai untuk menghindari double count.
5. Piutang, utang, dan deposit Customer harus mempunyai detail pihak serta
   dokumen terbuka. Ketiga template tersebut belum boleh diinjeksi sampai
   workflow opening subledger tersedia.
6. `24_opening_gl.csv` harus balance. Untuk cut-off tengah tahun, masukkan juga
   saldo YTD akun pendapatan dan beban agar laporan sistem sama dengan manual.
7. Setelah seluruh opening workflow tersedia dan diposting, saldo Opening
   Balance Clearing wajib nol.

## Yang sengaja tidak ada

- User, password, role, dan membership Company;
- transaksi historis Sale/Purchase/Expense sebagai transaksi palsu;
- Stock Movement, FIFO batch, Payment, Financial Event, atau Journal final
  melalui direct table write;
- detail register Aset dan depresiasi karena modul Aset detail masih deferred;
- audit/system row yang dibuat otomatis oleh server.

## Gate sebelum go-live

Jangan mulai transaksi live sebelum `25_reconciliation_control.csv` menunjukkan:

- Trial Balance debit = kredit;
- stok quantity dan valuasi FIFO = data manual;
- Inventory GL = valuasi FIFO;
- AR detail = AR GL;
- AP detail = AP GL;
- deposit Customer detail = liability GL;
- kas/bank = saldo cut-off manual;
- Opening Balance Clearing = 0;
- tidak ada queue aktif, exception Finance terbuka, atau dokumen opening Draft.

Saat ini hanya sepuluh template bertanda **IMPORT AKTIF** yang benar-benar dapat
diunggah. File **MENUNGGU RUNTIME** adalah data-collection contract, bukan izin
untuk direct SQL. Ini mencegah saldo go-live terlihat cocok di GL tetapi tidak
memiliki subledger dan jejak audit yang benar.
