# ACP-1 Access and Action Baseline Matrix

**Status:** LOCAL-READY FINGERPRINT — LIVE OUTPUT PENDING  
**Authority:** snapshot runtime sebelum custom permission  
**Requirement:** TEN-001, TEN-002, TEN-003, TEN-005

## 1. Tujuan

Matrix ini membekukan catalog yang terlihat sekarang dan memisahkan empat
lapisan yang sebelumnya mudah tercampur:

1. launcher/navigation visibility;
2. list/detail read melalui Route Handler/RLS;
3. mutation melalui Route Handler dan guarded RPC;
4. direct table privilege/RLS.

Role pada tabel adalah baseline maksimum, bukan custom permission. Capability
mutation final harus diverifikasi dari execution path masing-masing pada fase
cutover; label `VIEW` di navigation catalog tidak membuktikan hak POST/APPROVE.

## 2. Navigation Baseline Existing

| Permission key target | Navigation ID | Baseline role yang melihat | Cutover | Catatan aksi |
|---|---|---|---|---|
| `inventory.master_data` | `masters` | Owner, Admin, Store Manager, Warehouse Admin | ACP-4 | Category/UOM/Warehouse/Store/Terminal perlu dipecah bila mutation guard berbeda |
| `inventory.products` | `products` | Owner, Admin, Store Manager, Warehouse Admin | ACP-4 | Product + UOM atomic; Bundle terpisah |
| `inventory.stock_real` | `stock-real` | Owner, Admin, Store Manager, Warehouse Admin, Finance, Accounting | ACP-4 | Read-only saldo aktual |
| `inventory.stock_movements` | `stock-movements` | Owner, Admin, Store Manager, Warehouse Admin, Finance, Accounting | ACP-4 | Read-only immutable ledger |
| `inventory.stock_transfers` | `stock-transfers` | Owner, Admin, Store Manager, Warehouse Admin, Finance, Accounting | ACP-4 | VIEW lebih luas daripada operator; Post tetap guarded |
| `inventory.stock_adjustments` | `stock-adjustments` | Owner, Admin, Store Manager, Warehouse Admin, Finance, Accounting | ACP-4 | Warehouse Admin VIEW tetapi bukan canonical poster |
| `inventory.stock_opnames` | `stock-opnames` | Owner, Admin, Store Manager, Warehouse Admin, Finance, Accounting | ACP-4 | Count/review/post harus dipisah |
| `inventory.opening_stock` | `opening-stock` | Owner, Admin, Store Manager, Finance, Accounting | ACP-4 | Final post protected |
| `inventory.minimum_stock` | `minimum-stock` | Owner, Admin, Store Manager, Warehouse Admin | ACP-4 | Guarded configuration |
| `contacts.customers` | `customers` | Owner, Admin, Store Manager, Finance, Accounting | ACP-5 | POS quick-create tetap kontrak terpisah |
| `contacts.suppliers` | `suppliers` | Owner, Admin, Store Manager, Warehouse Admin, Finance, Accounting | ACP-5 | Product-Supplier berada dalam domain terkait |
| `contacts.staff_access` | `staff` | Owner, Admin | ACP-5 | Protected; hierarchy management wajib menang |
| `purchase.supplier_orders` | `supplier-orders` | Owner, Admin, Store Manager | ACP-5 | Draft/confirm dipisah |
| `purchase.purchase_returns` | `purchase-returns` | Owner, Admin, Store Manager | ACP-5 | Review/post/final effect protected |
| `sales.sales_documents` | `sales-documents` | Owner, Admin, Store Manager, Finance, Accounting | ACP-5 | Read/print/status delivery perlu aksi terpisah |
| `sales.pricelists` | `pricelists` | Owner, Admin, Store Manager, Finance, Accounting | ACP-5 | Master price mutation harus guarded |
| `sales.bundles` | `bundles` | Owner, Admin, Store Manager, Finance, Accounting | ACP-5 | Composition mutation dan availability read berbeda |
| `sales.sales_returns` | `sales-returns` | Owner, Admin, Store Manager | ACP-5 | Required approval/post tetap workflow canonical |
| `finance.expenses` | `expense-approvals` | Owner, Admin, Store Manager, Finance, Accounting + feature | ACP-6 | Request/review/disburse/settle dipisah |
| `finance.cash_deposits` | `cash-deposits` | Owner, Admin, Finance, Accounting | ACP-6 | Review/approve protected |
| `finance.deposit_variances` | `deposit-variances` | Owner, Admin, Finance, Accounting | ACP-6 | Assign/resolve/review maker-checker |
| `finance.customer_balances` | `customer-balances` | Owner, Admin, Finance, Accounting + feature | ACP-6 | Ledger immutable; correction maker-checker |
| `finance.supplier_invoices` | `supplier-invoices` | Owner, Admin, Finance, Accounting | ACP-6 | Match/validate protected |
| `finance.supplier_payments` | `supplier-payments` | Owner, Admin, Finance, Accounting | ACP-6 | Validate protected |
| `finance.payment_methods` | `payment-methods` | Owner, Admin, Finance, Accounting | ACP-6 | Store assignment/config mutation |
| `finance.tax_rules` | `tax-rules` | Owner, Admin, Finance, Accounting + feature | ACP-6 | Version/assignment guarded |
| `finance.master_data` | `finance-masters` | Owner, Admin, Finance, Accounting | ACP-6 | COA/category/mapping mempunyai guard berbeda |
| `finance.journals_reports` | `finance` | Owner, Admin, Finance, Accounting | ACP-6 | Report VIEW/export; period/reversal/queue protected |
| `data.exchange` | `data-exchange` | Owner, Admin, Store Manager, Warehouse Admin, Finance, Accounting | ACP-6 | Item-level EXPORT/IMPORT role matrix tetap berlaku |
| `platform.company_branding` | `company-branding` | Owner, Admin | ACP-6 | Manage only within active Company |
| `platform.module_settings` | `module-settings` | Owner, Admin, Store Manager | ACP-6 | Store Manager operational read/config only; entitlement Super Admin only |
| `platform.companies` | `companies` | Super Admin only | ACP-6 | Tidak custom-delegatable |

Super Admin melihat seluruh catalog, tetapi tetap wajib memilih active Company
untuk data tenant dan memakai workflow canonical.

## 3. Authority Pattern Existing yang Harus Dipertahankan

| Pattern | Runtime sekarang | ACP requirement |
|---|---|---|
| Active Company | Route mengambil `user_active_company_contexts`; data query memakai `company_id` | Resolver tidak menerima Company bebas dari payload browser |
| Role Company | `company_memberships.role_code`, maksimum satu row per user/Company | Tetap satu baseline role per Company |
| Store scope | `store_memberships` dan helper Store | Custom restriction tidak memperluas Store |
| Warehouse scope | Sebagian melalui document/RPC/warehouse assignment | ACP-1/4 harus membuktikan per route; jangan mengarang global warehouse role |
| Feature | `company_features` dan server guard | Feature OFF selalu menang |
| Navigation | `/api/me/navigation-catalog` + static server definitions | Harus memakai effective resolver setelah key enforced |
| Data Exchange | Catalog server mempunyai role per item/action | Harus di-intersect dengan effective permission, bukan hanya hide module |
| Final Stock/Finance | guarded RPC + RLS/revoke + immutable history | Tidak boleh berubah menjadi generic permission write |

## 4. Known Review Items Sebelum ACP-2

1. Route Handler belum memakai satu helper capability; terdapat inline role
   checks, shared helper, RPC role checks, dan RLS yang harus dibandingkan.
2. Navigation item saat ini umumnya hanya menyatakan `VIEW`; mutation capability
   belum menjadi catalog yang seragam.
3. `Master Inventory`, `Expense`, `Kategori & COA`, dan `Jurnal Keuangan`
   mengandung beberapa aksi dengan sensitivity berbeda dan mungkin perlu split
   key setelah audit route/RPC.
4. Warehouse scope tidak mempunyai satu membership table khusus; scope aktual
   berasal dari Company/Store, Warehouse/document eligibility, dan RPC. ACP tidak
   boleh menciptakan asumsi `warehouse membership` tanpa requirement baru.
5. Role Store dan Company dapat berbeda. Live diagnostic melaporkan divergence
   sebagai `REVIEW`, bukan otomatis corruption.

## 5. Freeze Rule

ACP-2 hanya boleh dimulai setelah output live ACP-1 ditinjau:

- semua `BLOCKER` nol;
- `REVIEW` direct-write dan role divergence dijelaskan;
- role UAT serta regular multi-Company identity cukup untuk regression, atau
  tetap ditandai `SETUP` dengan provisioning canonical;
- permission key/action split final dicatat pada revisi matrix ini.

Tidak adanya custom permission table adalah `SETUP` expected pada ACP-1.
