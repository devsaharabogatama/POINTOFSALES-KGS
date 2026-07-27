# G2 Phase 37 — Automatic Master Code UI Cutover

## Status

`READY FOR AUTHENTICATED SMOKE TEST`

## Outcome

Backoffice tidak lagi meminta atau menampilkan kode teknis untuk Product
Category, UOM, Warehouse, Supplier, Customer Category, Pricelist, Payment
Method, dan custom Transaction Category.

Create direct-table Category/UOM/Warehouse mengirim `NULL` agar trigger Phase 36
mengalokasikan kode. Lima master lainnya memakai overload guarded RPC tanpa
parameter kode. Update selalu mempertahankan kode existing.

Product SKU, Customer code, COA account code, Tax code, barcode, serta kode
Product milik Supplier tetap user-facing karena merupakan identitas bisnis.

## Local Evidence

- `npm.cmd run lint`: PASS;
- `npm.cmd run build`: PASS;
- Next.js production build mengenali seluruh route master;
- tidak ada schema migration baru pada cutover ini.

## Manual Smoke

Restart Backoffice lalu, pada Company aktif:

1. buat dan edit Product Category, UOM, serta Warehouse hanya memakai nama dan
   field bisnis lainnya;
2. pastikan save sukses, list hanya menampilkan nama, dan edit tidak memunculkan
   `SYSTEM_CODE_IMMUTABLE`;
3. ulangi create/edit untuk Supplier, Customer Category, Pricelist, Payment
   Method, dan satu custom Transaction Category;
4. buka Product, Supplier-Product, Customer, Pricing, Payment, dan Finance untuk
   memastikan dropdown tetap menampilkan nama;
5. pastikan Product SKU, Customer code, COA, Tax, barcode, dan kode Product
   Supplier tetap terlihat sesuai kontraknya;
6. pastikan Escape menutup modal.

Nama duplikat harus ditolak server.

## Import/Export Compatibility

UI Import/Export empat master existing masih memakai kontrak CSV berkode.
Boundary ini sengaja dipertahankan karena validator/commit Phase 30–33 yang
sudah applied masih mengenali explicit code. Full-import gate berikut harus:

- menghapus kode teknis dari template create delapan target;
- memakai referensi nama yang unambiguous;
- mempertahankan explicit-code compatibility untuk file lama selama transisi;
- menguji preview/commit existing sebelum kontrak lama didepresiasi.

Jangan mengubah migration Phase 30–33 yang sudah applied.

## Compatibility

- UUID dan 41 kode legacy tidak berubah;
- allocator tetap tenant-scoped, transactional, dan concurrency-safe;
- tidak ada stock, checkout, payment transaction, tax calculation, atau journal
  yang diaktifkan.

## Next Safe Step

Setelah authenticated smoke PASS, lanjutkan additive full Master Import/Export
validator/commit dan template create tanpa kode teknis. Opening Stock tetap
menunggu G3.
