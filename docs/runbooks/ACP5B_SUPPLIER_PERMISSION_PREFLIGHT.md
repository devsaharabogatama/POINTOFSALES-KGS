# ACP-5B Supplier Permission Preflight

## Tujuan

Mengaudit satu key `contacts.suppliers` sebelum enforcement. Tahap ini hanya
membaca metadata dan agregat; tidak mengubah schema, grant, Supplier,
Product-Supplier, dokumen Purchase/AP, override, ataupun import job.

Boundary ini mencakup pengelolaan identitas Supplier, rekening referensi, dan
relasi Product-Supplier. Authority transaksi tetap terpisah:

- Supplier Order dan Purchase Return memakai permission Purchase masing-masing;
- Supplier Invoice, tolerance policy, dan Supplier Payment memakai permission
  Finance masing-masing;
- Product management hanya menerima reference Product-Supplier yang sempit;
- Data Exchange Supplier dan Product-Supplier membutuhkan capability
  `IMPORT`/`EXPORT` eksplisit.

## Urutan Eksekusi

1. Buka SQL Editor Supabase menggunakan owner/admin database.
2. Jalankan seluruh isi
   `supabase/diagnostics/acp_phase5b_supplier_permission_preflight.sql`.
3. Kirim seluruh baris `check_name,status,details`.
4. Berhenti bila ada `BLOCKER`.

`REVIEW` dan `SETUP` adalah target desain rollout berikutnya, bukan error dan
bukan izin untuk langsung menyalakan enforcement.

## Expected Sebelum Enforcement

- dependency ACP-5A, catalog, schema, tenant, normalized identity, preferred
  Supplier, Product-UOM pembelian, dokumen operasional, import job, dan direct
  write boundary `PASS`;
- composed Supplier read dan capability hook masih `SETUP`;
- direct read, shared consumers, authority split, dan import/export muncul
  sebagai `REVIEW`;
- tidak ada Supplier, rekening, harga referensi/terakhir, Purchase/AP, stock,
  atau audit yang berubah karena diagnostic ini.

## Setelah Output Direview

Baru buat rollout atomic untuk Supplier management: guarded composed read,
capability-aware Supplier/Product-Supplier mutation dan import/export,
Backoffice cutover, direct table-read closure, postflight, role/two-Company
behavior, serta regression Purchase Order/Receipt/Return, Finance Invoice/AP/
Payment, Product reference, dan Data Exchange. Consumer API harus mengotorisasi
permission miliknya sendiri; parameter purpose dari client tidak boleh menjadi
bypass.
