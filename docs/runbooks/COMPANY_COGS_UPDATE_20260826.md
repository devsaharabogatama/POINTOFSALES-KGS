# Pembaruan COGS LSM, SMS, dan KMS — 26 Agustus 2026

Status: **operation ready; database belum dijalankan oleh Codex**.

## Sumber dan Batasan

- Sumber: `Price List Distributor 26082026.xlsx`.
- SHA-256:
  `c3d3385935a3b6270c22d43dc9aae2844bc35b837f50ad19e028f99617f33218`.
- Sheet `Sheet1`, 45 SKU, tidak ada COGS invalid atau SKU duplikat.
- COGS sumber adalah nilai untuk satu `PACK`.
- Target dijalankan terpisah untuk Company `LSM`, `SMS`, dan `KMS`.
- SKU yang tidak ditemukan dilewati dan wajib diperiksa pada hasil preview.
- Operasi tidak menyentuh Retail, harga jual, Pricelist, UOM nonaktif, Stock,
  FIFO, transaksi final, Financial Event, atau Journal.
- Persediaan lama tidak direvaluasi. Harga transaksi final tetap memakai
  snapshot pada saat transaksi tersebut diposting.

## File yang Dijalankan

1. [Operasi preview/apply](../../supabase/operations/update_company_product_cogs_from_20260826_pricelist.sql)
2. [Postflight tiga Company](../../supabase/diagnostics/company_product_cogs_20260826_postflight.sql)

Jangan memakai Import Pricelist Distributor untuk pekerjaan ini karena import
tersebut juga memperbarui Retail, harga jual, dan Pricelist.

## Urutan Eksekusi

Untuk setiap Company, mulai dari `LSM`, kemudian `SMS`, lalu `KMS`:

1. Buka file operasi dan ubah hanya `target_company_identifier`.
2. Pastikan `execute_change=FALSE` dan `confirmation=''`.
3. Salin dan jalankan **seluruh isi file** pada Supabase SQL Editor.
4. Pastikan semua baris berstatus `BLOCKER` bernilai `PASS`.
5. Periksa `unmatched_sku_scope`. SKU yang tidak terdapat pada Company akan
   berstatus `SKIPPED` dan tidak ditulis.
6. Periksa tabel detail. Product valid harus memiliki tepat satu PACK aktif,
   `pack_factor` positif, serta `new_base_cogs` yang masuk akal.
7. Ubah:

   ```sql
   execute_change := TRUE
   confirmation := 'UPDATE_COMPANY_COGS_20260826'
   ```

   Secara aktual kedua nilai tersebut berada pada baris `INSERT INTO
   kgs_cogs_update_config`; gunakan `TRUE` dan token yang sama persis.
8. Jalankan kembali seluruh file.
9. Pastikan `final_cogs_verification=PASS`.
10. Kembalikan file lokal ke `execute_change=FALSE` agar tidak salah apply.

Setelah ketiga Company selesai, jalankan postflight. Semua hasil selain `INFO`
wajib `PASS`.

## Rumus

Untuk setiap Product:

```text
base_cogs = COGS Excel per PACK / factor_to_base PACK
purchase_price UOM aktif = base_cogs × factor_to_base UOM
```

Contoh COGS PACK Rp14.630 dan faktor PACK 10:

```text
products.cogs = Rp1.463 per base UOM
Product-UOM PACK.purchase_price = Rp14.630
```

## Forward-fix

Tidak disediakan rollback yang menyalin nilai lama secara buta karena harga
master baru dapat dipakai oleh transaksi setelah APPLY. Jika nilai sumber
salah, koreksi payload dengan bukti sumber yang benar lalu jalankan operasi
baru melalui preview/apply. Snapshot transaksi POSTED tidak boleh diedit.
