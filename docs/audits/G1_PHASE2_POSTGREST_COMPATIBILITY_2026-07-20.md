# G1 Fase 2 — PostgREST Relationship Compatibility

**Tanggal:** 2026-07-20  
**Status:** CODE FIX VERIFIED; deployment/smoke user pending

## Gejala

Setelah composite tenant foreign key G1 fase 2 dipasang, Backoffice tetap mengenali Company aktif `KGS`, tetapi menampilkan notifikasi `Gagal memuat data perusahaan`.

## Root Cause

Context Company dimuat melalui route terpisah dan tetap berhasil. Kegagalan terjadi pada query katalog yang memakai embedded relationship:

```text
products -> product_stocks -> warehouses
```

G1 fase 2 sengaja mempertahankan FK legacy dan menambahkan composite FK. PostgREST kemudian melihat dua relationship valid pada pasangan table yang sama. Embed tanpa relationship hint menjadi ambigu dan dapat menghasilkan `PGRST201`.

## Perbaikan

- Backoffice Product/Stock query sekarang memilih FK legacy secara eksplisit.
- PWA master-data sync memakai hint FK legacy yang sama.
- Composite FK tidak dihapus; database tetap menolak cross-company reference.
- Error normalizer Backoffice sekarang membaca field `message` dari `PostgrestError`, sehingga error berikutnya tidak disamarkan menjadi toast generik.

FK legacy dipakai sebagai API hint karena tersedia sebelum dan sesudah migration. Tenant integrity tetap dijaga composite FK pada setiap write.

## Evidence

- Query REST read-only dengan hint baru: HTTP 200.
- Backoffice ESLint: 0 error, satu warning existing `Truck` unused.
- Backoffice production build: PASS.
- PWA oxlint: PASS.
- PWA TypeScript + Vite production build: PASS.

## Manual Exit

1. Deploy/restart Backoffice dan PWA build terbaru.
2. Hard refresh Backoffice.
3. Pastikan Product/Stock data termuat tanpa notification error.
4. Jalankan PWA master-data sync jika PWA sudah dipakai.
5. Jika masih gagal, simpan exact toast baru dan request Network terkait.
