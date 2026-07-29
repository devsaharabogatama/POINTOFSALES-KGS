# G2 Phase 45 — Product-Supplier Import UI

## Status

`READY FOR AUTHENTICATED SMOKE TEST`

Database Phase 44 dikonfirmasi user seluruhnya PASS pada 2026-07-27.
Backoffice lint dan production build Phase 45 juga PASS.

## Outcome

Menu **Import & Export** sekarang memiliki tipe
**Relasi Produk–Supplier** dengan kontrak fixed:

```text
product_sku,supplier_name,purchase_uom_name,supplier_product_code,reference_purchase_price,is_preferred_supplier,is_active
```

- template create tidak menampilkan ID internal;
- export update menambahkan `internal_id`;
- export memakai SKU Product, nama Supplier, dan nama UOM;
- preview tidak menampilkan UUID;
- preview menjelaskan harga referensi, Supplier utama/alternatif, dan status;
- UI menjelaskan cara mengganti Supplier utama dalam satu file;
- error tenant/reference/preferred/version dari server diterjemahkan ke bahasa
  user;
- transaksi, harga pembelian terakhir, dan stock tidak disentuh.

## File berubah

- `backoffice/src/lib/master-import.ts`;
- `backoffice/src/app/api/master/import-export/route.ts`;
- `backoffice/src/components/MasterImportView.tsx`.

## Evidence lokal

```text
npm.cmd run lint  -> PASS
npm.cmd run build -> PASS
```

Build mendeteksi route dinamis:

```text
/api/master/import-export
/api/master/import-jobs
/api/master/import-jobs/[id]
```

## Smoke test manual

1. Restart Backoffice.
2. Buka **Import & Export**.
3. Pilih **Relasi Produk–Supplier**.
4. Unduh template dan pastikan tujuh header fixed tersedia tanpa
   `internal_id`.
5. Export data dan pastikan:
   - `internal_id` tersedia hanya untuk update;
   - Product tampil sebagai SKU;
   - Supplier dan UOM tampil sebagai nama, bukan UUID/kode sistem.
6. Import satu relation baru yang valid:
   - pilih Product stock aktif;
   - pilih Supplier aktif;
   - gunakan nama UOM pembelian milik Product;
   - periksa preview sebelum commit.
7. Uji update melalui file export dan konfirmasi jumlah update tepat.
8. Uji pergantian Supplier utama:
   - relation lama `is_preferred_supplier=false`;
   - relation baru `is_preferred_supplier=true`;
   - keduanya berada pada file yang sama.
9. Pastikan typo nama Supplier/UOM menjadi row error dan tidak membuat master
   baru.
10. Pastikan riwayat import dapat dibuka kembali tanpa notifikasi error.

## Compatibility

- semua tipe import Phase 34/39/41/43 tetap memakai kontrak lama;
- public import RPC dan schema tidak berubah pada Phase 45;
- query export menggabungkan tabel secara terpisah sehingga tidak bergantung
  pada nested PostgREST relationship/schema cache;
- Product Import, Opening Stock, Minimum Stock, Purchase, dan stock ledger
  tidak berubah.

## Next safe step

Setelah smoke PASS, lanjutkan dependency order fixed import ke
**Minimum Stock Produk–Gudang preflight**. Opening Stock tetap dokumen
inventory terpisah pada G3.
