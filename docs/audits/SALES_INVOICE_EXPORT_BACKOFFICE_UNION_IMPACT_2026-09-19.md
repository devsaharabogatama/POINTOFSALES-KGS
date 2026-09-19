# Sales Invoice Export Backoffice Union — Impact Audit

## Root cause

Data Exchange `SALES_DOCUMENTS` memanggil `public.export_sales_documents(date,date)`, tetapi runtime tersebut hanya membaca `sales_invoice_snapshots` milik alur Retail. Invoice Office berada pada `backoffice_sales_invoices` dan karena itu tidak pernah masuk file XLSX walaupun sudah tampil di workspace Invoice Penjualan.

## Approved scope

- Gabungkan Invoice Retail dan Backoffice pada export yang sama.
- Sertakan seluruh status Backoffice: `DRAFT`, `POSTED`, `CANCELED`, dan `REVERSED`.
- Tambahkan identitas sumber, nomor dokumen, nomor Invoice, nomor Draft, nomor SO, dan status agar dapat difilter.
- Pertahankan detail Produk, UOM, qty, harga, diskon, pajak, dan total per baris.
- Invoice tetap export-only; tidak membuka import Invoice.

## Impact map

Direct impact:

- `public.export_sales_documents(date,date)` sebagai RPC read-only.
- formatter workbook pada API Data Exchange Sales Documents.

Downstream impact:

- Sheet `Daftar Invoice`, `Detail Produk`, dan metadata export memperoleh kolom tambahan.
- Consumer lama tetap menerima key Retail lama; perubahan JSON hanya additive.

Tidak terdampak:

- pembuatan/posting/revisi/pembatalan Invoice dan SO;
- Stock, reservation, FIFO, Purchase, Payment, Cashier Session, jurnal, serta antrean Finance;
- histori transaksi dan permission mutation;
- jalur import Data Exchange.

## Compatibility and risk controls

- Tanggal Retail tetap memakai resolver tanggal Invoice lama; tanggal Backoffice memakai `invoice_date` kanonik.
- Nomor dokumen Backoffice memakai `invoice_no` bila sudah terbit dan `draft_no` bila masih Draft.
- Detail nonproduk seperti Down Payment tetap diekspor dan ditandai melalui `Jenis Baris`/`Efek Baris`.
- Filter Excel sudah diterapkan oleh generator XLSX ke seluruh header sheet.
- Tidak ada backfill atau perubahan baris transaksi.

## Unproven until manual rollout

- hasil preflight, migration, behavioral test, dan postflight pada database target;
- authenticated download dari UI Data Exchange;
- perbandingan jumlah/status/detail Invoice terhadap workspace produksi.

