# Global Role-Aware Data Exchange Center

**Status:** APPROVED; DEX-1 complete, DEX-2/DEX-3 user-accepted, DEX-4 local-ready  
**Disetujui:** 2026-08-11  
**Target:** pre-deploy Backoffice consolidation

## 1. Keputusan

Backoffice memiliki satu entry point global `Import & Export`. User tidak
melihat seluruh tipe data; katalog yang tersedia dihitung dari active Company,
akses modul/submodul, scope Store/Gudang, serta permission aksi `EXPORT` atau
`IMPORT`.

Import/Export yang sekarang berada di modul Inventory dipensiunkan setelah
global center mencapai feature parity dan authenticated smoke PASS. Entry point
lama tidak boleh dihapus lebih dahulu karena akan memutus workflow existing.

## 2. Flow User

1. Pilih Company hanya bila user mempunyai akses lebih dari satu Company.
2. Pilih aksi `Export` atau `Import`.
3. Pilih modul yang diizinkan server.
4. Pilih jenis data yang diizinkan di dalam modul tersebut.
5. Isi filter/export format atau upload template versioned untuk import.
6. Preview, validasi, explicit confirmation, proses, dan lihat history/result.

UUID/internal key tetap digunakan backend dan tidak menjadi label utama user.
Template menggunakan nama atau kode bisnis yang dapat di-resolve secara
tenant-safe.

## 3. Authority

Visibility UI bukan authorization. Server wajib memvalidasi ulang:

```text
active Company access
AND module/submodule permission
AND EXPORT or IMPORT action permission
AND Store/Warehouse/data scope
AND object-specific business guard
```

Permission `EXPORT` dan `IMPORT` terpisah. User dapat diberi export read-only
tanpa hak import. Super Admin tetap lintas Company; role lain tidak boleh
melampaui membership dan operational scope-nya.

## 4. Jenis Data

### Export dan Import melalui staging guarded

- master user-creatable yang sudah didukung fixed template;
- Product + Product-UOM sebagai satu atomic group;
- Product-Supplier;
- Minimum Stock Product-Warehouse;
- master tambahan hanya setelah validator/RPC-nya tersedia.

### Export-only

- Stock aktual, FIFO valuation, Kartu Stok, Movement, dan source posted;
- Sales, Return, Payment, Purchase, Receipt, Invoice, Expense, Deposit;
- Journal Entries, General Ledger, Trial Balance, Income Statement, Balance
  Sheet, Pending Analysis, dan Reconciliation;
- audit/history dan system-owned rows yang tidak boleh dimutasi user.

Laporan Finance diekspor sebagai XLSX berdasarkan Accounting Period/filter
tanggal, timezone Company, report version, serta access scope. Export tidak
boleh membaca raw table di luar canonical report/read contract.

### Workflow khusus, bukan generic import

- Opening Stock;
- Manual Journal dan Opening Balance Finance;
- posted transaction correction/reversal;
- Company, user/password, role/membership, feature entitlement;
- final Stock/FIFO/Movement, Payment, Financial Event, dan Journal.

## 5. Cutover Inventory

1. inventaris seluruh tipe dan call path Import/Export Inventory existing;
2. bangun server-owned role-aware catalog;
3. pindahkan reusable template/export/import history ke global center;
4. uji parity, tenant isolation, negative permission, dan fixed template;
5. ubah navigation Inventory menjadi link ke global center dengan type filter;
6. hapus entry point lama hanya setelah user smoke PASS; backend compatibility
   dipertahankan sampai seluruh caller berpindah.

## 6. Delivery Phases

1. **DEX-1 — Access/catalog audit:** map module/submodule permissions, existing
   import types, export contracts, dan unsafe direct readers.
2. **DEX-2 — Role-aware export center:** global navigation, catalog RPC/API,
   Finance XLSX, filters, history, and cross-tenant negative tests.
3. **DEX-3 — Import consolidation:** reuse staging/preview/partial commit,
   object-specific validator, fixed template, and separate import permission.
4. **DEX-4 — Inventory cutover:** parity smoke, redirect/deprecate legacy entry
   point, regression, and deployment evidence.

Evidence DEX-1 berada di
`audits/DEX1_GLOBAL_DATA_EXCHANGE_ACCESS_CATALOG_AUDIT_2026-08-11.md`. Audit
menutup inventaris execution path dan mengunci kontrak DEX-2; tidak mengubah
menu, API, grant, atau runtime existing.

DEX-2 implementation dan manual gate berada di
`runbooks/DEX2_ROLE_AWARE_EXPORT_CENTER.md`. Global export runtime sudah
local-ready, tetapi belum boleh disebut complete sebelum authenticated
role/cross-Company/XLSX smoke PASS.

DEX-3 implementation dan parity gate berada di
`runbooks/DEX3_GLOBAL_IMPORT_CONSOLIDATION.md`. Global Import memakai ulang
fixed template, staging, preview, guarded commit, dan history existing. Entry
point Inventory tetap dipertahankan sampai DEX-4 karena authenticated parity
smoke belum dijalankan.

User menerima tampilan DEX-3 pada 2026-08-11. DEX-4 cutover dan deployment
evidence berada di
`runbooks/DEX4_INVENTORY_CUTOVER_AND_DEPLOYMENT_EVIDENCE.md`. Entry point lama
telah dihapus dari navigation lokal, sedangkan component/API/RPC compatibility
tetap dipertahankan. Closing cross-role/cross-Company smoke masih manual.

## 7. Pre-Deploy Acceptance

- server and UI return the same authorized catalog;
- unauthorized module/type/action returns stable denial even if URL/API called
  directly;
- cross-Company/Store/Warehouse export and import negative tests PASS;
- Finance exports reconcile with on-screen canonical POSTED reports;
- import remains tenant-scoped, previewed, audited, idempotent, and guarded;
- no generic import path can write posted/final operational or Finance history;
- legacy Inventory entry point is removed only after parity and user smoke.
