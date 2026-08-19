# Import Additive UOM Product

## Status

Local-ready. Migration database dan smoke test user masih wajib dijalankan.

## Perilaku

- Data Exchange menyediakan tipe `PRODUCT_UOM`.
- Template CSV berisi satu baris kosong per Product aktif non-Bundle dan dijaga
  dengan capability `IMPORT`; hak `EXPORT` tidak diperlukan untuk memperoleh
  template referensi ini.
- Baris dengan `uom_name` kosong dilewati tanpa error.
- Baris terisi menambah atau memperbarui pasangan `product_sku + uom_name`.
- Saat memperbarui pasangan existing, kolom izin, harga, dan barcode yang
  dibiarkan kosong mempertahankan nilai existing agar template additive tidak
  menonaktifkan UOM secara tidak sengaja.
- UOM Product lain tidak dinonaktifkan atau dihapus.
- Base UOM tidak dapat diubah melalui jalur ini.
- UOM baru yang menjadi faktor terbesar wajib mempunyai `weight_if_largest_kg`.
- Faktor UOM existing yang sudah mempunyai Stock Movement tetap immutable.
- Seluruh mutation tenant-scoped, `IMPORT`-guarded, optimistic, dan masuk audit
  Product. Browser tidak memperoleh RPC direct-write UOM; commit memakai private
  core setelah preview tervalidasi.

## Urutan rollout

1. Selesaikan rollout Customer exchange `20260819150000` terlebih dahulu.
2. Pastikan tidak ada import job nonterminal.
3. Jalankan `supabase/migrations/20260819160000_product_uom_additive_import_export.sql`.
4. Jalankan `supabase/diagnostics/product_uom_additive_import_export_postflight.sql`; seluruh baris wajib `PASS`.
5. Jalankan `supabase/tests/product_uom_additive_import_export_tests.sql`; hasil harus sukses dan otomatis `ROLLBACK`.
6. Jalankan postflight ulang, lalu deploy/restart Backoffice.
7. Smoke: Data Exchange → Inventory → Tambah / Perbarui UOM Produk →
   Template CSV → isi satu baris → preview → commit.

## Kolom

`product_sku,product_name,uom_name,factor_to_base,purchase_allowed,sales_allowed,purchase_price,sale_price,barcode,weight_if_largest_kg`

Jika perlu lebih dari satu UOM baru pada Product yang sama, duplikasi baris Product.
Jangan mengubah `product_sku` atau `product_name` hasil Template CSV.
