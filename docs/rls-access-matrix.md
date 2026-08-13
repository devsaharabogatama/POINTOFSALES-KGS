# RLS Access Matrix (Multi-Company)

**Status:** BUSINESS HIERARCHY APPROVED; exact policy SQL masih wajib diaudit dan ditulis ulang sebelum implementasi.

> Extension approved 2026-08-12: role tetap baseline dan batas maksimum,
> sedangkan custom permission hanya boleh membatasi per submodul pada Company
> terkait. Contract, governance, phased cutover, dan compatibility ada di
> `ROLE_BASELINE_CUSTOM_PERMISSION_PLAN.md`. Sembilan key Inventory, Customer,
> Supplier, Supplier Order, Purchase Return, Sales Document, Pricelist, dan
> Bundle sudah database-live ENFORCED. ACP-5H Sales Return preflight lulus tanpa
> blocker dan seluruh rollout/regression kemudian user-confirmed PASS. Seluruh
> ACP-5 database-live ENFORCED; ACP-6A Expense juga user-confirmed database-live
> ENFORCED. ACP-6B Cash Deposit baru SELECT-only preflight dan Finance key
> lainnya masih SHADOW.

Keputusan hierarchy:

- `SUPER_ADMIN` memiliki seluruh kewenangan lintas company.
- `COMPANY_ADMIN` memiliki seluruh kewenangan role bawahan, termasuk Finance/Jurnal, hanya dalam company membership-nya.
- `STORE_MANAGER`, `FINANCE/ACCOUNTING`, `WAREHOUSE_ADMIN`, dan `CASHIER` dibatasi scope/action masing-masing.
- Company Admin/Super Admin tetap wajib memakai workflow posting/reversal; full authority bukan izin UPDATE/DELETE ledger, movement, atau jurnal final secara langsung.
- Adjustment dapat diposting Store Manager atau Company Admin/Super Admin; Warehouse Admin tidak dapat mem-posting Adjustment.
- Cashier hanya boleh quick-create Customer melalui RPC/API terkontrol; bukan INSERT tabel langsung.
- Hanya Super Admin dapat mengubah seluruh feature entitlement per company, termasuk `customer_balance_enabled` dan `ketul_enabled`. Company Admin tidak mewarisi hak memunculkan/meniadakan feature, tetapi dapat mengatur konfigurasi operasional setelah fitur aktif. Enforcement wajib berlaku pada UI dan mutation API/RPC.

Matriks kebijakan Row Level Security (RLS) di Supabase database untuk mengamankan isolasi tenant per perusahaan.

| Role | Tabel | Select | Insert | Update | Delete | Keterangan / Scope |
| :--- | :--- | :---: | :---: | :---: | :---: | :--- |
| **SUPER_ADMIN** | Semua data tenant |  | Melalui workflow | Melalui workflow | ❌ final ledger | Seluruh company; wajib mempertahankan company asal dan audit actor. |
| **COMPANY_OWNER** | Semua Tabel |  |  |  | ❌ | Otoritas penuh untuk melihat dan merubah data perusahaannya sendiri. Tidak boleh menghapus data transaksi finansial final. |
| **COMPANY_ADMIN** | Semua data company termasuk Jurnal |  | Melalui workflow | Melalui workflow | ❌ final ledger | Seluruh kewenangan operasional/Finance hanya pada company membership aktif. |
| **FINANCE / ACCOUNTING**| `financial_events`, `journal_entries` |  | ❌ | ❌ | ❌ | Audit pembukuan perusahaan, tidak diperkenankan insert/update jurnal secara manual (harus otomatis lewat worker/trigger). |
| **CASHIER** | `sales_headers`, `sales_payments` |  |  | ❌ | ❌ | Boleh membuat transaksi melalui RPC kasir, hanya bisa melihat sesi kasir miliknya sendiri. |
| **CASHIER** | `products`, `customers` |  | RPC quick-create Customer | ❌ direct update | ❌ | Baca katalog; quick-create Customer hanya melalui RPC/API terkontrol. |
| **CASHIER** | `journal_entries` | ❌ | ❌ | ❌ | ❌ | Di-block penuh dari data akuntansi jurnal buku besar. |
| **WAREHOUSE_ADMIN**| `product_stocks`, `stock_movements` |  | Melalui workflow transfer | ❌ direct balance/movement | ❌ | Kelola gudang, transfer sesuai scope, dan lihat mutasi; tidak boleh posting Adjustment. |
| **STORE_MANAGER** | Data store, opname, adjustment, refund/return |  | Melalui workflow | Melalui workflow | ❌ final document | Scope store assignment; Company Admin/Super Admin mewarisi action ini. |

Customer ACP-5A menjaga boundary berikut: Owner/Admin/Store Manager mengelola
identitas; Finance/Accounting hanya View plus limit/termin kredit melalui
authority Finance; Cashier quick-create tetap open-session scoped; Sales dan
Finance membaca label Customer melalui reference API modulnya sendiri.

Supplier ACP-5B menerapkan boundary setara: Contacts Manage menguasai identitas,
bank reference, dan Product-Supplier; Purchase serta Finance mengambil label
melalui reference RPC modulnya sendiri; Kasir hanya melihat Supplier yang
terkait Order/Receipt pada Store dengan sesi aktif. Direct table read/write
Supplier ditutup setelah rollout manual.

Sales Return ACP-5H memisahkan Backoffice `VIEW/POST/CANCEL_FINAL` dari source
dan Draft PWA yang hanya berlaku pada sesi Kasir OPEN serta Store-nya. Final
Post tetap atomik, restore FIFO asal/Bundle allocation, dan menghasilkan satu
Finance event HOLD. Capability Backoffice tidak memperluas scope Kasir, dan
direct read tabel Return ditutup setelah composed RPC kedua channel aktif.

---

## 🔒 Aturan Isolasi Utama (RLS Policy Query)
Semua filter Select, Insert, Update, dan Delete didasarkan pada helper SQL berikut:
```sql
-- Memastikan user memiliki membership aktif pada company tersebut
user_has_company_access(target_company_id) = TRUE
```
Dan bagi staf toko (kasir):
```sql
-- Memastikan kasir ditugaskan pada toko terkait
user_has_store_access(target_store_id) = TRUE
```
