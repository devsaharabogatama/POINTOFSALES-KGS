# Rollout Template Kontekstual UOM Product dan Pembatalan Job

## Hasil yang dituju

- Template dan Export `PRODUCT_UOM` menampilkan seluruh UOM existing sebagai
  baris `REFERENCE`, urut dari faktor terkecil ke terbesar.
- Setelah UOM existing setiap Product terdapat tepat satu baris `INPUT` kosong.
- Hanya baris `INPUT` yang masuk staging. Baris `REFERENCE` tidak pernah
  dimutasi dan tidak perlu dihapus dari CSV.
- Baris Product-UOM yang valid tetap dapat di-commit sementara baris error
  tetap berada di preview dan dapat diunduh untuk diperbaiki.
- Job `UPLOADED`, `MAPPED`, `VALIDATED`, atau `READY` dapat dibatalkan manual.
- Job milik user yang tetap `UPLOADED/MAPPED` lebih dari 15 menit otomatis
  dibatalkan saat Riwayat Import dimuat.
- Saat migration diterapkan, job Product-UOM lama yang masih nonterminal pada
  empat status tersebut ditutup sebagai `CANCELED` dengan audit event.

## Urutan rollout

1. Jalankan `supabase/migrations/20260821100000_product_uom_context_template_job_cancel.sql`.
2. Jalankan `supabase/diagnostics/product_uom_context_template_job_cancel_postflight.sql`.
   Seluruh status selain baris inventory `INFO` wajib `PASS`.
3. Jalankan migration forward-fix
   `supabase/migrations/20260821110000_product_uom_partial_validation_restore.sql`.
4. Jalankan
   `supabase/diagnostics/product_uom_partial_validation_restore_postflight.sql`.
5. Jalankan `supabase/tests/product_uom_partial_validation_restore_tests.sql`.
6. Jalankan `supabase/tests/product_uom_context_template_job_cancel_tests.sql`.
   Test harus sukses dan berakhir `ROLLBACK`.
7. Deploy Backoffice staging.
8. Download Template `Tambah / Perbarui UOM Produk`. Pastikan setiap Product
   mempunyai baris `REFERENCE` existing dan satu baris `INPUT` kosong terakhir.
9. Isi satu baris INPUT valid, preview, lalu commit.
10. Ulangi dengan satu baris valid dan satu UOM tidak dikenal. Baris valid
   harus tetap dapat disimpan dan baris error dapat diunduh.
11. Buat job lalu hentikan sebelum validasi; buka Riwayat Import dan gunakan
   **Batalkan job**.

## Cara mengisi

Jangan mengubah `row_mode`, SKU, atau nama Product pada baris referensi. Isi
kolom pada baris `INPUT`. Contoh 1 DUS = 10 KETUL dengan berat 18 kg:

```csv
row_mode,product_sku,product_name,uom_name,factor_to_base,purchase_allowed,sales_allowed,purchase_price,sale_price,barcode,weight_if_largest_kg
REFERENCE,BK1,Daging Kebab,KETUL,1,true,true,50000,58500,,
INPUT,BK1,Daging Kebab,DUS,10,true,true,500000,585000,,18
```

Duplikasi baris `INPUT` jika satu Product membutuhkan lebih dari satu UOM baru.
Nama UOM harus sudah ada dan aktif di Master Data UOM.

## Compatibility dan forward-fix

- Product, UOM existing, Stock, FIFO, Movement, harga historis, dan transaksi
  tidak dihapus atau diganti oleh template.
- Import Product penuh tetap memakai grouped Product contract lama.
- Jangan membuka direct write tabel import atau Product-UOM. Jika rollout UI
  harus ditunda, RPC lama tetap tersedia tetapi client baru hanya boleh dipakai
  setelah migration ini berhasil.
