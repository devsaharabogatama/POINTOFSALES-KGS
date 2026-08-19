# Index Requirement MVP POS v1 KGS

**Status:** APPROVED scope freeze sebelum implementasi  
**Tanggal freeze:** 2026-07-20  
**Tujuan:** menjadi pintu masuk requirement POS v1, bukan pengganti spesifikasi modul.  
**Aturan:** perubahan scope harus dicatat pada dokumen modul sumber dan decision log sebelum masuk implementasi.

---

## 1. Scope POS v1 yang Dibangun

POS v1 mencakup enam kelompok kemampuan berikut:

1. tenant, role, feature entitlement, Store, POS Terminal, dan Warehouse;
2. master Produk, Kategori Produk, UOM, konversi satu tingkat, Gudang, Supplier, Customer, Pricelist, Payment Method, Transaction Category, Tax, dan COA minimum;
3. inventory: opening stock, stock real, movement, transfer, Stock Opname, Adjustment, FIFO/HPP, Bundle, dan laporan;
4. POS: sesi kasir, checkout online/offline, pembayaran, TEMPO, rounding, receipt, Return, Expense, Setor Kas, dan notifikasi;
5. purchasing dasar: Request Order, Supplier Order, penerimaan partial, Return Supplier, invoice/AP provisional, dan matching minimum;
6. integrasi Finance: immutable source event, jurnal double-entry, AR/AP, reconciliation, period lock, report minimum, serta link bukti eksternal.

Fitur Ketul dan Customer Balance termasuk POS v1, tetapi hanya aktif pada Company yang entitlement-nya dinyalakan oleh Super Admin.

---

## 2. Scope yang Ditunda

| Scope | Status | Boundary v1 |
|---|---|---|
| Manufacture/MRP | DEFERRED | Product, UOM, Warehouse, movement, lot/batch, dan event source harus dapat dipakai ulang tanpa mengubah transaksi POS lama. |
| HR/payroll | DEFERRED | User/role tidak boleh dicampur dengan employee/payroll ledger. |
| Logistics advanced | DEFERRED | v1 hanya membutuhkan gudang/lokasi sederhana, transfer, penerimaan, dan delivery reference. |
| Aset tetap detail | DEFERRED | Hanya catatan arah, account boundary, dan source-document extensibility; workflow aset dibahas terpisah. |
| e-Faktur/integrasi pajak pemerintah | DEFERRED | Tax engine internal disiapkan, integrasi resmi belum dibangun. |
| Upload file internal | DEFERRED dengan exception logo Company | Bukti transaksi tetap URL eksternal. User 2026-08-11 membuka upload internal hanya untuk logo Company yang dipakai template dokumen. |

Deferred berarti tidak boleh diam-diam masuk schema/UI v1. Extensibility disiapkan melalui ID stabil, source document, status history, event, dan mapping—bukan dengan membangun modulnya sekarang.

---

## 3. Peta Requirement dan Source of Truth

| ID | Domain | Requirement ringkas | Source of truth | Gate |
|---|---|---|---|---|
| TEN-001 | Tenant | Semua data operasional terkunci pada `company_id`; Store/Warehouse/POS tetap konsisten dengan Company. | `../KGS_BACKOFFICE_AUTH_FLOW_WORKFLOW.md`, `rls-access-matrix.md` | G1 |
| TEN-002 | Role | Super Admin lintas Company; Company Admin penuh hanya pada Company miliknya; role lain sesuai Store/Warehouse/Finance scope. | `../KGS_BACKOFFICE_AUTH_FLOW_WORKFLOW.md`, `rls-access-matrix.md` | G1 |
| TEN-003 | Feature | Hanya Super Admin dapat menyalakan/mematikan modul Company, termasuk Ketul dan Customer Balance. | `ERP_EVOLUTION_ARCHITECTURE_NOTES.md`, spesifikasi modul terkait | G1 |
| TEN-004 | Branding | Company dapat memiliki logo opsional yang tenant-scoped, audited, aman untuk template dokumen, dan memiliki fallback tanpa logo. | `PREDEPLOY_MODULAR_HOME_BRANDING_SALES_DOCUMENT_PLAN.md` | Pre-deploy |
| TEN-005 | Custom Access | Role per Company tetap baseline dan batas maksimum; Company Admin ke atas dapat memberi pembatasan opsional per submodul, tanpa memperluas role, feature, Store/Warehouse scope, atau workflow final. Tanpa override harus identik dengan behavior role existing. | `ROLE_BASELINE_CUSTOM_PERMISSION_PLAN.md`, `rls-access-matrix.md` | Pre-deploy ACP |
| APP-001 | Launcher | Home hanya menampilkan modul authorized; klik modul membuka landing card submodul authorized sebelum halaman kerja. | `PREDEPLOY_MODULAR_HOME_BRANDING_SALES_DOCUMENT_PLAN.md` | Pre-deploy |
| MST-001 | Product | SKU manual; nama, kategori, harga beli/jual fallback, berat manual, UOM terbesar sebagai acuan berat, status aktif. | `PRODUCT_STOCK_MASTERDATA_SPEC.md` | G2 |
| MST-002 | UOM | Stok disimpan pada UOM terkecil; maksimal satu tingkat turunan pada v1; harga jual per UOM dapat berbeda. | `PRODUCT_STOCK_MASTERDATA_SPEC.md`, `UOM_WEIGHT_VALUATION_SPEC.md` | G2 |
| MST-003 | Category | Kategori Produk adalah master dan dapat membawa fallback COA; mapping transaksi tetap prioritas. | `PRODUCT_STOCK_MASTERDATA_SPEC.md`, `TRANSACTION_CATEGORY_ACCOUNT_MAPPING_SPEC.md` | G2 |
| MST-004 | Warehouse | Kode manual maksimal lima huruf; empat tipe dasar; lokasi sederhana; akses operasional terkontrol. | `PRODUCT_STOCK_MASTERDATA_SPEC.md` | G2 |
| MST-005 | Import | Export master dahulu; import memakai ID atau nama/kode; dry-run/mapping; update diberi warning; sukses parsial; history; opening stock terpisah. | `PRODUCT_STOCK_MASTERDATA_SPEC.md` | G2 |
| MST-009 | Global Data Exchange | Satu Import/Export Center global menampilkan hanya modul/submodul dan aksi yang diizinkan server; export/import terpisah, Finance/report export-only, generic import tidak boleh menyentuh histori posted/final, dan entry point Inventory lama dipensiunkan setelah parity. | `GLOBAL_DATA_EXCHANGE_CENTER_SPEC.md` | Pre-deploy |
| MST-006 | Customer | Nama unik per Company; phone/email boleh sama; kategori Customer; status dan saldo terkontrol. | `SALES_CUSTOMER_MASTERDATA_SPEC.md` | G2 |
| MST-007 | Pricing | Harga Produk hanya fallback; Customer Pricelist mengalahkan Global; tier hanya Global; scope all/specific Store. | `SALES_PRICELIST_NOTES.md` | G2/G4 |
| MST-008 | Payment | Metode pembayaran adalah master Company; mendukung Cash, Transfer, QRIS, Card, TEMPO, split, fee, dan konfigurasi offline. | `PAYMENT_METHOD_MASTERDATA_SPEC.md` | G2/G4 |
| STK-001 | Stock | `stock_real` tersimpan dalam base UOM per Product-Warehouse; default transaksi final tidak boleh negatif. Exception POS hanya boleh dibuka melalui STK-006. | `PRODUCT_STOCK_MASTERDATA_SPEC.md` | G3 |
| STK-006 | Negative Stock | Fitur POS opsional default OFF; Company/Warehouse/actor harus berizin, online-only, audited, source-linked, idempotent, dan kekurangan FIFO/HPP wajib direkonsiliasi saat replenishment. Sisa shortage per sesi otomatis menjadi satu Stock Request `SUBMITTED` ketika sesi ditutup agar Purchasing dapat membaginya per Supplier Order. | Keputusan user 2026-08-05 dan 2026-08-19; `POS_DEVELOPMENT_NOTES.md`, `PRODUCT_STOCK_MASTERDATA_SPEC.md`, `runbooks/PRD_NEGATIVE_STOCK_SESSION_REQUEST_ROLLOUT.md` | G4/G5/G6 |
| STK-002 | Movement | Semua perubahan stok memiliki immutable movement dan source document yang jelas. | `PRODUCT_STOCK_MASTERDATA_SPEC.md` | G3 |
| STK-003 | Opening | Opening Stock hanya initial load; koreksi berikutnya melalui Adjustment. | `PRODUCT_STOCK_MASTERDATA_SPEC.md` | G3 |
| STK-004 | Opname | Kasir input blind count per sesi; Store Manager membandingkan/posting; transaksi tetap berjalan; adjustment memakai stock akhir. | `PRODUCT_STOCK_MASTERDATA_SPEC.md` | G3/G4 |
| STK-005 | FIFO | Receipt membentuk layer FIFO; sale/return/adjustment menjaga allocation dan HPP konsisten. | `PRODUCT_STOCK_MASTERDATA_SPEC.md`, `UOM_WEIGHT_VALUATION_SPEC.md` | G3 |
| STK-006 | Bundle | Bundle punya SKU sendiri, hanya berisi Product stok biasa, dan mengurangi komponen; tidak ada nested Bundle. | `PRODUCT_STOCK_MASTERDATA_SPEC.md`, `BUNDLE_REVENUE_ALLOCATION_SPEC.md` | G3/G4 |
| POS-001 | Session | Saldo awal manual; kasir melihat stock awal, keluar sesi, masuk, dan stock terkini; close menghasilkan flow kas. | `POS_DEVELOPMENT_NOTES.md` | G4 |
| POS-002 | Checkout | Server menjadi sumber kebenaran untuk product/UOM/price/tax/discount/rounding/stock/HPP/payment totals. | `POS_DEVELOPMENT_NOTES.md` dan dependency modul | G4 |
| POS-003 | Stock shortage | Penjualan tidak final saat stok kurang; menjadi Draft dengan notice dan bisa dilanjutkan setelah stock tersedia. | `PRODUCT_STOCK_MASTERDATA_SPEC.md`, `POS_DEVELOPMENT_NOTES.md` | G4 |
| POS-004 | Offline | Draft/sale offline memiliki allowance, idempotency key, retry state, acknowledgement, dan exception flow; sync tidak boleh menggandakan transaksi. | `POS_DEVELOPMENT_NOTES.md` | G4 |
| POS-005 | TEMPO | Kasir boleh memberi tempo/due date dengan warning; pembayaran satu pintu dari POS; Finance dapat override dan mengawasi AR. | `COLLECTION_AND_CUSTOMER_STATEMENT_SPEC.md` | G4/G6 |
| POS-006 | Customer Balance | Entitlement opsional; saldo lama wajib habis pada transaksi berikutnya; koreksi kasir perlu approval Finance. | `SALES_CUSTOMER_MASTERDATA_SPEC.md` | G4/G6 |
| POS-007 | Expense | Cash Advance ditiadakan; satu Expense flow, source Cash/Transfer, optional approval, settlement/return, kategori menentukan COA. | `POS_EXPENSE_CASH_FLOW_SPEC.md` | G4/G6 |
| POS-008 | Deposit | Satu setoran dapat memilih beberapa sesi; sistem vs real boleh selisih; posting setelah approval Finance. | `DEPOSIT_VARIANCE_RESOLUTION_SPEC.md` | G4/G6 |
| POS-009 | Evidence | Transfer dan bukti lain memakai URL eksternal, bukan upload ke Supabase Storage pada v1. | `EXTERNAL_EVIDENCE_LINK_POLICY.md` | G4 |
| POS-010 | Ketul | Optional Company feature; receipt dari Customer, discount/cash/balance, stock Ketul, sale ke Vendor, reject/damage/return, Finance confirmation. | `KETUL_WORKFLOW_NOTES.md` | G4/G6 |
| POS-011 | Sales Document | Sale POSTED mempunyai Sales Invoice printable; delivery dipilih pada final checkout, Customer menjadi default recipient, ongkir opsional masuk total dan Finance terpisah, serta Sale delivery menghasilkan Surat Jalan tanpa Stock/Finance effect kedua. | `PREDEPLOY_MODULAR_HOME_BRANDING_SALES_DOCUMENT_PLAN.md`, `SLD_DELIVERY_FEE_REVISION_PLAN.md` | Pre-deploy |
| PUR-001 | Purchasing | Sales/Kasir membuat Request Order; Store Manager menentukan Supplier/qty dan membuat Supplier Order. | `PRODUCT_STOCK_MASTERDATA_SPEC.md` | G5 |
| PUR-002 | Receipt | Kasir menerima partial/lebih dengan source order; accepted/rejected/damaged tercatat; stock hanya dari accepted. | `PRODUCT_STOCK_MASTERDATA_SPEC.md` | G5 |
| PUR-003 | AP | Receipt membentuk provisional AP/valuation; Finance mencocokkan invoice fisik dan harga real sebelum payment. | `PURCHASE_MATCHING_TOLERANCE_SPEC.md` | G5/G6 |
| PUR-004 | Return | Store Manager membuat Return Supplier; stock, AP/Debit Note, dan status sumber harus konsisten. | `PRODUCT_STOCK_MASTERDATA_SPEC.md`, `DEBIT_CREDIT_NOTE_SPEC.md` | G5/G6 |
| FIN-001 | Event | Transaksi operasional final menghasilkan immutable/idempotent Financial Event; Draft tidak menjurnal. | `FINANCE_INTEGRATION_NOTES.md` | G6 |
| FIN-002 | COA | COA tiga tingkat default, kode/nama dapat disesuaikan Finance; account function dan Transaction Category resolver dapat direkonsiliasi. | `FINANCE_CORE_ACCOUNTING_SPEC.md`, `TRANSACTION_CATEGORY_ACCOUNT_MAPPING_SPEC.md` | G6 |
| FIN-003 | Journal | Posting double-entry balance, mempunyai source trace, version snapshot, reversal/adjustment, approval, dan period lock. | `FINANCE_CORE_ACCOUNTING_SPEC.md` | G6 |
| FIN-004 | AR/AP | TEMPO, collection partial, pro forma, customer statement, Supplier invoice, payment, return, dan note tidak boleh mengubah histori posted. | Finance/Purchase/Sales specs | G6 |
| FIN-005 | Tax | Pajak opsional per Company dan per module Sales/Purchase; resolver dapat dioverride Finance dengan audit. | `TAX_ENGINE_SPEC.md` | G6 |
| FIN-006 | Reports | Trial Balance, GL, P&L, Balance Sheet, AR/AP aging, cash/deposit, stock valuation, pending/draft/hold, dan reconciliation. | `FINANCE_REPORTING_AND_CUTOFF_SPEC.md` | G6 |

---

## 4. Invariant Lintas Modul

Invariant berikut tidak boleh dikompromikan oleh UI atau shortcut operasional:

1. ID dari Company A tidak boleh dipakai dalam dokumen Company B, termasuk Product, Store, Warehouse, Customer, Supplier, Payment Method, Tax, COA, dan user membership.
2. Semua nilai final—harga, diskon, pajak, rounding, payment total, qty base, stock, FIFO, HPP, AR/AP—dihitung ulang dan divalidasi server-side.
3. Draft/Hold/Pending tidak membuat stock movement atau jurnal, kecuali dokumen khusus yang spesifikasinya menyatakan reservation/allowance.
4. Satu business event final hanya boleh menghasilkan satu efek stock dan satu set jurnal aktif; retry mengembalikan hasil yang sama.
5. Koreksi transaksi posted dilakukan dengan Return, Debit/Credit Note, Adjustment, atau reversal; histori lama tidak dihapus/ditimpa.
6. Setiap stock movement dan journal line harus dapat ditelusuri ke Company, source document, actor, waktu, dan version.
7. Super Admin dapat lintas Company, tetapi pemilihan active Company tetap eksplisit agar operasi tidak salah tenant.
8. Feature yang disabled tidak hanya disembunyikan dari UI; API/RPC juga harus menolak operasinya.

---

## 5. Definition of Done POS v1

POS v1 baru boleh disebut siap pilot jika:

- seluruh item G1–G6 pada `POS_V1_IMPLEMENTATION_GATES.md` lulus;
- tidak ada blocker terbuka pada `PRE_BUILD_IMPLEMENTATION_GAP_AUDIT_2026-07-20.md`;
- migration dan backfill teruji dari database kosong serta snapshot staging;
- matrix RLS/API/RPC diuji untuk Super Admin, Company Admin, Store Manager, Warehouse Admin, Finance, dan Cashier;
- transaction replay, concurrent stock update, offline retry, dan accounting balance test lulus;
- pilot dibatasi satu Company, satu Store, satu Terminal lebih dahulu;
- rollback teknis dan rollback operasional telah dicoba sebelum cutover.
