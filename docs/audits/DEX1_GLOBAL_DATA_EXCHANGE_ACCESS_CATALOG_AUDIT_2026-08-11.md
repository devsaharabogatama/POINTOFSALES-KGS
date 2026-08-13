# DEX-1 Global Data Exchange Access/Catalog Audit

**Status:** COMPLETE (repository audit)  
**Tanggal:** 2026-08-11  
**Requirement:** `MST-009`  
**Runtime impact:** tidak ada; menu dan API existing belum dipindahkan

## 1. Outcome

DEX-1 memetakan jalur aktif Import/Export Backoffice dan menetapkan boundary
implementasi DEX-2. Audit ini tidak menyatakan Global Data Exchange Center sudah
aktif. Entry point `Inventory > Import & Export` wajib tetap tersedia sampai
DEX-4 parity dan authenticated smoke selesai.

## 2. Execution Path Existing

### Master import/export

```text
Backoffice page.tsx (role array OWNER_ROLES)
  -> MasterImportView
     -> GET /api/master/import-export (template/data CSV)
     -> GET/POST /api/master/import-jobs
     -> GET/PATCH /api/master/import-jobs/:id
        -> create/stage/validate/commit_master_import_job RPC
        -> master_import_jobs/rows/events
```

Seluruh route memakai authenticated caller, active Company context, lalu
`requireImportManager()`. Guard tersebut memakai `canManageCompany()` dan saat
ini hanya menerima Super Admin atau membership aktif `COMPANY_OWNER` /
`COMPANY_ADMIN`. Hak export dan import belum dipisahkan.

### Finance report/export

```text
FinanceOperationsView
  -> GET /api/finance/operations (canonical report RPC)
  -> GET /api/finance/operations/export (monthly XLSX)
```

Report layar sudah memanggil RPC canonical untuk Trial Balance, Income
Statement, Balance Sheet, Pending Analysis, Reconciliation Summary, dan General
Ledger. Export XLSX baru mendukung `GENERAL_LEDGER` dan `JOURNAL_ENTRIES`.
Route export membaca `finance_journals`/`finance_journal_lines` tenant-scoped dan
memakai Trial Balance RPC untuk metadata/saldo, tetapi belum mempunyai guard
role Finance eksplisit pada layer API.

## 3. Katalog Existing

| Module target | Type | Export | Import | Source sekarang | Keputusan DEX |
|---|---|---:|---:|---|---|
| Inventory | Product Category | CSV | guarded | direct tenant read + job RPC | reuse |
| Inventory | UOM | CSV | guarded | direct tenant read + job RPC | reuse |
| Inventory | Warehouse | CSV | guarded | direct tenant read + job RPC | reuse |
| Contacts/Purchase | Supplier | CSV | guarded | direct tenant read + job RPC | reuse |
| Contacts | Customer Category | CSV | guarded | direct tenant read + job RPC | reuse |
| Finance | Chart of Account | CSV | guarded custom rows | direct tenant read + job RPC | reuse; system rows export-only |
| Finance | Transaction Category | CSV | guarded custom rows | direct tenant read + job RPC | reuse; system rows export-only |
| Inventory | Product + Product-UOM | CSV | guarded atomic group | multi-table tenant read + job RPC | reuse |
| Purchase | Product-Supplier | CSV | guarded | multi-table tenant read + job RPC | reuse |
| Inventory | Minimum Stock Product-Warehouse | CSV | guarded | multi-table tenant read + job RPC | reuse |
| Finance | Journal Entries | XLSX | no | canonical journal tables | expose through DEX-2 |
| Finance | General Ledger | XLSX | no | journal tables + report RPC | expose through DEX-2 |
| Finance | Trial Balance | screen only | no | canonical report RPC | add XLSX in DEX-2 |
| Finance | Income Statement | screen only | no | canonical report RPC | add XLSX in DEX-2 |
| Finance | Balance Sheet | screen only | no | canonical report RPC | add XLSX in DEX-2 |
| Finance | Pending Analysis | screen only | no | canonical report RPC | add XLSX in DEX-2 |
| Finance | Reconciliation Summary | screen only | no | canonical report RPC | add XLSX in DEX-2 |

Stock Real, FIFO valuation, Kartu Stok/Movement, transaksi Sales/Purchase,
Return, Payment, Receipt, Expense, Deposit, dan audit/history belum memiliki
katalog export global. Semuanya tetap export-only saat ditambahkan; generic
import tidak boleh dibuka untuk data tersebut.

## 4. Temuan Access dan Safety

### DEX-1-A — catalog masih client-owned

Pilihan tipe berasal dari `importDefinitions` pada bundle Backoffice. User dapat
memanggil URL API secara langsung, sehingga visibility client tidak dapat
menjadi authority. DEX-2 wajib menyediakan katalog hasil evaluasi server dan
memvalidasi kembali `moduleKey + typeKey + action` pada setiap request.

### DEX-1-B — EXPORT dan IMPORT belum terpisah

Semua download template/data serta seluruh import job memakai guard Owner/Admin
yang sama. Ini aman secara konservatif, tetapi belum memenuhi hak export
read-only untuk role operasional/Finance. DEX-2 tidak boleh melonggarkan
`requireImportManager`; buat authority baru untuk export, lalu DEX-3 memisahkan
authority import.

### DEX-1-C — belum ada grant submodule per user

Repository hanya membuktikan Company/Store membership dan role arrays per view;
belum ditemukan model grant module/submodule/action per user. DEX-2 memakai
role + Company/Store/Warehouse scope existing sebagai baseline server-owned.
Granular override per user adalah perluasan authorization tersendiri dan tidak
boleh dipalsukan dengan state client.

### DEX-1-D — Finance export belum lengkap dan guard API belum eksplisit

Hanya dua tipe XLSX tersedia. Route mengandalkan RLS/RPC tetapi tidak melakukan
penolakan role Finance eksplisit. DEX-2 wajib menambahkan shared server
authorization untuk seluruh Finance export, menjaga Company active context,
dan memakai canonical report/read contract yang sama dengan layar.

### DEX-1-E — direct readers perlu registry, bukan copy-paste route

Master CSV export mempunyai percabangan direct read untuk sepuluh tipe dan
limit 5.000 baris. Kode ini tenant-scoped, tetapi katalog, label, format, limit,
dan resolver tersebar. DEX-2 harus membungkus export provider dalam registry
server-owned; route lama tetap compatibility caller sampai DEX-4.

## 5. Target Contract DEX-2

Server mengembalikan hanya item yang boleh dilihat caller:

```ts
type DataExchangeCatalogItem = {
  moduleKey: 'INVENTORY' | 'CONTACTS' | 'PURCHASE' | 'SALES' | 'FINANCE'
  typeKey: string
  label: string
  allowedActions: Array<'EXPORT' | 'IMPORT'>
  formats: Array<'CSV' | 'XLSX'>
  scopeKind: 'COMPANY' | 'STORE' | 'WAREHOUSE'
  templateVersion?: string
  exportOnly: boolean
  filters: string[]
}
```

Authority minimum setiap request:

```text
authenticated caller
AND active Company membership
AND eligible role for module/type/action
AND requested Store/Warehouse belongs to active Company and caller scope
AND object-specific feature/business guard
```

Stable denial: `DATA_EXCHANGE_ACTION_FORBIDDEN` (403). Type yang tidak dikenal
atau tidak terdaftar: `DATA_EXCHANGE_TYPE_UNSUPPORTED` (400). Server tidak
boleh mengungkap tipe yang tidak diizinkan melalui catalog response.

## 6. DEX-2 Implementation Map

1. Tambahkan shared server registry dan evaluator catalog/action; jangan taruh
   secret atau service role pada browser.
2. Tambahkan authenticated catalog API dan negative tests untuk role serta
   cross-Company/Store/Warehouse.
3. Buat global navigation/page memakai response catalog, bukan role array untuk
   menentukan action akhir.
4. Pindahkan dua Finance XLSX existing ke provider registry dan lengkapi lima
   report canonical lain dengan filter periode/tanggal yang sama dengan layar.
5. Pertahankan route `/api/master/import-export`, import job API, dan entry point
   Inventory sebagai compatibility path.
6. DEX-2 belum membuka import untuk role baru dan belum menghapus menu lama.

## 7. Acceptance DEX-2

- catalog UI sama dengan catalog server untuk caller yang sama;
- direct API call yang tidak berhak mendapat 403 stabil;
- role Inventory tidak otomatis melihat Finance export, dan role Finance tidak
  otomatis memperoleh import master;
- scope Company/Store/Warehouse lintas tenant ditolak;
- tujuh Finance XLSX memakai canonical report/read contract dan reconcile
  dengan hasil layar pada filter identik;
- route/menu existing tetap bekerja sampai DEX-4.

## 8. Evidence dan Batas Verifikasi

Audit dilakukan terhadap:

- `backoffice/src/app/page.tsx`;
- `backoffice/src/components/MasterImportView.tsx`;
- `backoffice/src/lib/master-import.ts`;
- `backoffice/src/lib/master-import-server.ts`;
- `backoffice/src/lib/server-auth.ts`;
- route Master Import/Export dan Finance Operations aktif.

Tidak ada migration, data mutation, grant, route, atau UI yang diubah pada
DEX-1. Live role/cross-tenant test dimulai setelah DEX-2 runtime tersedia.
