# Rollout Penyelarasan Template Dokumen Penjualan

## Scope

- Invoice A4 POS mengikuti template resmi Backoffice.
- Nota thermal POS tetap terpisah dan tidak berubah.
- Template tanda tangan Surat Jalan dipilih per Company:
  - `WAREHOUSE`: Warehouse, Security, Driver, Customer;
  - `STORE`: Kasir, Ekspedisi, Customer.
- Logo, stempel, rekening Invoice, tanggal Invoice, dan template Surat Jalan
  disnapshot pada dokumen baru agar reprint stabil.

## Urutan Supabase

1. `supabase/diagnostics/sales_document_template_alignment_preflight.sql`
2. `supabase/migrations/20260827151000_sales_document_template_alignment.sql`
3. `supabase/tests/sales_document_template_alignment_postflight.sql`
4. `supabase/tests/sales_document_template_alignment_behavior.sql`
5. Jalankan postflight sekali lagi.

## Smoke

1. Di `Platform -> Profil Perusahaan`, pilih template Gudang.
2. POST Sale DELIVERY baru; cetak Surat Jalan dari POS dan Backoffice. Keduanya
   wajib menampilkan empat label Gudang yang sama.
3. Pilih template Toko dan POST Sale DELIVERY baru. Keduanya wajib menampilkan
   Kasir, Ekspedisi, Customer.
4. Cetak Invoice A4 transaksi baru dari POS dan Backoffice. Susunan field,
   tanggal, logo/stempel/rekening, item, total, dan ketiadaan tanda tangan harus
   sama. Nota thermal tidak boleh berubah.
5. Cetak ulang dokumen langkah 2 setelah setting diganti; template lama wajib
   tetap Gudang.

## Compatibility

Default Company adalah `WAREHOUSE`. Dokumen lama tidak ditulis ulang dan kedua
renderer memakai fallback Gudang bagi snapshot lama yang belum memiliki pilihan
template.
