# DEX-2 Role-Aware Export Center

**Status:** LOCAL-READY; authenticated smoke pending  
**Requirement:** `MST-009`  
**Schema/migration:** tidak ada

## 1. Outcome

DEX-2 menambahkan satu halaman global Data Exchange yang memperoleh katalog
export dari server. Visibility UI bukan authority: download master CSV,
Finance screen report, dan Finance XLSX memvalidasi ulang active Company,
membership role, type, dan action pada API.

Entry point `Inventory > Import & Export` tetap aktif. Import tetap memakai
Owner/Admin guard dan staging/job RPC existing sampai DEX-3 selesai.

## 2. Role Baseline

| Data | Role export |
|---|---|
| Product Category, UOM, Warehouse, Product, Minimum Stock | Owner, Admin, Store Manager, Warehouse Admin |
| Supplier dan Product-Supplier | Owner, Admin, Store Manager, Warehouse Admin, Finance, Accounting |
| Customer Category | Owner, Admin, Store Manager, Finance, Accounting |
| COA, Transaction Category, seluruh Finance report | Owner, Admin, Finance, Accounting |
| Import master existing | Owner/Admin saja; belum dipindahkan |

Super Admin dapat melihat seluruh katalog pada active Company. Role tanpa item
yang diizinkan mendapat katalog kosong. API direct call yang tidak berhak wajib
menghasilkan `DATA_EXCHANGE_ACTION_FORBIDDEN`.

## 3. Finance XLSX

Tujuh tipe tersedia dengan filter bulan:

1. Journal Entries;
2. General Ledger;
3. Trial Balance;
4. Income Statement;
5. Balance Sheet;
6. Pending Analysis;
7. Reconciliation Summary.

Lima statement/report baru memanggil RPC canonical yang sama dengan layar.
General Ledger dan Journal Entries mempertahankan canonical journal/read path
existing. File berisi report rows, summary, metadata Company/timezone/periode,
generated-at, dan report version. Pending Analysis mengikuti limit canonical
500 grouping per request; hasil tidak dimasukkan sebagai jurnal POSTED.

## 4. Automated Evidence

Jalankan dari `backoffice`:

```powershell
npx.cmd eslint src/lib/data-exchange-server.ts src/app/api/data-exchange/catalog/route.ts src/app/api/master/import-export/route.ts src/app/api/finance/operations/route.ts src/app/api/finance/operations/export/route.ts src/components/DataExchangeView.tsx src/app/page.tsx
npm.cmd run build
```

Expected:

- lint tanpa error/warning;
- production build dan TypeScript PASS;
- route `/api/data-exchange/catalog` terdeteksi dynamic;
- route Master Import/Export dan Finance Operations existing tetap terdeteksi.
- unauthenticated production-server smoke untuk catalog dan Finance export
  menghasilkan HTTP 401 JSON `AUTHENTICATION_REQUIRED`, bukan HTML/redirect.

## 5. Authenticated Smoke

Restart Backoffice, lalu gunakan active Company pilot.

### Owner/Admin

1. Buka aplikasi `Data Exchange` dari home.
2. Pastikan 10 master CSV dan tujuh Finance XLSX terlihat.
3. Export satu Product CSV, satu Journal Entries XLSX, dan satu statement XLSX.
4. Pastikan menu Import & Export Inventory lama masih dapat membuka template,
   preview, history, dan guarded commit seperti sebelumnya.

### Finance/Accounting

1. Pastikan Finance report, COA, Transaction Category, Supplier, dan
   Product-Supplier export terlihat.
2. Pastikan Product/UOM/Warehouse export tidak terlihat bila role tersebut
   tidak mempunyai Inventory access.
3. Panggil langsung master type yang tidak diizinkan; expected HTTP 403
   `DATA_EXCHANGE_ACTION_FORBIDDEN`.
4. Pastikan Import Inventory lama tidak terlihat/tidak dapat digunakan.

### Store Manager dan Warehouse Admin

1. Pastikan hanya katalog operasional yang sesuai role terlihat.
2. Pastikan Finance XLSX tidak terlihat.
3. Panggil langsung Finance export; expected HTTP 403.

### Cross-Company

1. Untuk user multi-Company, ganti active Company dan muat ulang katalog.
2. Pastikan filename/isi berasal dari Company baru.
3. Jangan mengirim `company_id` dari client; API selalu memakai active context.
4. User tanpa membership active wajib ditolak `COMPANY_ACCESS_DENIED`.

## 6. Finance Reconciliation Smoke

Pada bulan/filter identik:

- total Trial Balance XLSX sama dengan layar Neraca Saldo;
- P&L, Balance Sheet, Pending, dan Reconciliation rows/summary sama dengan
  canonical report layar;
- General Ledger hanya memakai journal POSTED;
- Journal Entries boleh memuat status dokumen untuk audit;
- HOLD/deferred tetap hanya muncul pada Pending Analysis.

## 7. Compatibility dan Rollback

Tidak ada schema/data migration. Rollback teknis adalah menghapus global view,
catalog route, dan shared evaluator, lalu mengembalikan guard export master ke
`requireImportManager`. Jangan menghapus route/job/import existing.

Jika smoke permission gagal, jangan melonggarkan RLS atau RPC. Nonaktifkan
entry point global secara UI sementara dan perbaiki registry/evaluator
server-side.

## 8. Next Safe Step

Setelah authenticated smoke PASS, lanjut DEX-3 Import consolidation:

- global UI memakai katalog action `IMPORT`;
- reuse template/staging/validate/commit/history existing;
- import tetap Owner/Admin sampai model granular action resmi tersedia;
- object final/posted tetap export-only;
- Inventory entry point belum dihapus sampai DEX-4 parity smoke.
