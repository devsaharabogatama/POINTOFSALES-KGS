# RLS Access Matrix (Multi-Company)

Matriks kebijakan Row Level Security (RLS) di Supabase database untuk mengamankan isolasi tenant per perusahaan.

| Role | Tabel | Select | Insert | Update | Delete | Keterangan / Scope |
| :--- | :--- | :---: | :---: | :---: | :---: | :--- |
| **COMPANY_OWNER** | Semua Tabel |  |  |  | ❌ | Otoritas penuh untuk melihat dan merubah data perusahaannya sendiri. Tidak boleh menghapus data transaksi finansial final. |
| **COMPANY_ADMIN** | Semua Tabel (kecuali Jurnal) |  |  |  | ❌ | Manajemen produk, gudang, kasir, toko, dan pelanggan. |
| **FINANCE / ACCOUNTING**| `financial_events`, `journal_entries` |  | ❌ | ❌ | ❌ | Audit pembukuan perusahaan, tidak diperkenankan insert/update jurnal secara manual (harus otomatis lewat worker/trigger). |
| **CASHIER** | `sales_headers`, `sales_payments` |  |  | ❌ | ❌ | Boleh membuat transaksi melalui RPC kasir, hanya bisa melihat sesi kasir miliknya sendiri. |
| **CASHIER** | `products`, `customers` |  |  | ❌ | ❌ | Hanya boleh membaca (SELECT) katalog produk dan data pelanggan untuk checkout. |
| **CASHIER** | `journal_entries` | ❌ | ❌ | ❌ | ❌ | Di-block penuh dari data akuntansi jurnal buku besar. |
| **WAREHOUSE_ADMIN**| `product_stocks`, `stock_movements` |  |  |  | ❌ | Mengatur penyesuaian fisik barang, transfer stok gudang, dan melihat laporan mutasi. |

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
