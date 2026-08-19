# Router Dokumen KGS POS

Panduan penggunaan untuk operator dan pengguna akhir tersedia di
[`MANUAL_PENGGUNA_KGS_POS.md`](MANUAL_PENGGUNA_KGS_POS.md).

Paket pengumpulan data dan urutan cutover go-live tersedia di
[`templates/go-live-cutover/README.md`](templates/go-live-cutover/README.md).
Paket tersebut membedakan template yang sudah dapat di-import, form setup
manual, workflow Stok Awal, serta opening Finance/subledger yang masih menunggu
runtime resmi.

Controlled operation untuk membersihkan data transaksi/uji coba milik satu
Company sebelum cutover tersedia di
[`runbooks/PRD_COMPANY_TRANSACTIONAL_DATA_RESET.md`](runbooks/PRD_COMPANY_TRANSACTIONAL_DATA_RESET.md).
Operasi default ke preview dan bukan bagian dari migration deployment.

Koreksi salah import UOM dan Kategori Produk sebelum UAT tersedia di
[`runbooks/PRD_GUARDED_INVENTORY_MASTER_CLEANUP.md`](runbooks/PRD_GUARDED_INVENTORY_MASTER_CLEANUP.md).
Hard delete hanya berlaku untuk master tanpa referensi; master yang sudah
dipakai wajib dinonaktifkan.

Rollout import/export Customer dan penambahan UOM Product secara additive:

- [`runbooks/PRD_CUSTOMER_MASTER_IMPORT_EXPORT.md`](runbooks/PRD_CUSTOMER_MASTER_IMPORT_EXPORT.md)
- [`runbooks/PRD_PRODUCT_UOM_ADDITIVE_IMPORT_EXPORT.md`](runbooks/PRD_PRODUCT_UOM_ADDITIVE_IMPORT_EXPORT.md)

Finance G6 Phase 8:

- [`runbooks/G6_PHASE8_OPERATIONAL_HOLD_CONTRACT_PREFLIGHT.md`](runbooks/G6_PHASE8_OPERATIONAL_HOLD_CONTRACT_PREFLIGHT.md)
- [`runbooks/G6_PHASE8A_SALE_RETURN_POSTING_PREFLIGHT.md`](runbooks/G6_PHASE8A_SALE_RETURN_POSTING_PREFLIGHT.md)
- [`runbooks/G6_PHASE8A_SALE_RETURN_SETTLEMENT_MAPPING_ROLLOUT.md`](runbooks/G6_PHASE8A_SALE_RETURN_SETTLEMENT_MAPPING_ROLLOUT.md)
- [`runbooks/G6_PHASE8B_SALE_RETURN_POSTING_RUNTIME_ROLLOUT.md`](runbooks/G6_PHASE8B_SALE_RETURN_POSTING_RUNTIME_ROLLOUT.md)
- [`runbooks/G6_PHASE8C_SALE_RETURN_CONTROLLED_QUEUE_ROLLOUT.md`](runbooks/G6_PHASE8C_SALE_RETURN_CONTROLLED_QUEUE_ROLLOUT.md)
- [`runbooks/G6_PHASE8D_PURCHASE_AP_POSTING_PREFLIGHT.md`](runbooks/G6_PHASE8D_PURCHASE_AP_POSTING_PREFLIGHT.md)
- [`runbooks/G6_PHASE8D_PURCHASE_AP_POSTING_RUNTIME_ROLLOUT.md`](runbooks/G6_PHASE8D_PURCHASE_AP_POSTING_RUNTIME_ROLLOUT.md)
- [`runbooks/G6_PHASE8E_PURCHASE_AP_CONTROLLED_QUEUE_ROLLOUT.md`](runbooks/G6_PHASE8E_PURCHASE_AP_CONTROLLED_QUEUE_ROLLOUT.md)
- [`runbooks/G6_PHASE8F_REMAINING_OPERATIONAL_POSTING_PREFLIGHT.md`](runbooks/G6_PHASE8F_REMAINING_OPERATIONAL_POSTING_PREFLIGHT.md)
- [`runbooks/G6_PHASE8F_REMAINING_OPERATIONAL_RUNTIME_ROLLOUT.md`](runbooks/G6_PHASE8F_REMAINING_OPERATIONAL_RUNTIME_ROLLOUT.md)
- [`runbooks/G6_PHASE8G_REMAINING_OPERATIONAL_QUEUE_ROLLOUT.md`](runbooks/G6_PHASE8G_REMAINING_OPERATIONAL_QUEUE_ROLLOUT.md)

Gunakan file ini sebagai entrypoint. Jangan membaca seluruh folder `docs` untuk setiap tugas.

Ringkasan aplikasi, cara menjalankan, status modul, dan kebijakan living README
berada di [`../README.md`](../README.md).

## Paket Baca per Modul

| Tugas | Baca minimum | Dependency bila relevan |
|---|---|---|
| Produk, UOM, Gudang, Import, Stock | `PRODUCT_STOCK_MASTERDATA_SPEC.md` | `FINANCE_INTEGRATION_NOTES.md` hanya untuk accounting boundary |
| POS, sesi, offline, print, notifikasi | `POS_DEVELOPMENT_NOTES.md` | Product/Stock untuk movement; Customer/Pricelist bila checkout |
| Expense dan arus kas non-penjualan | `POS_EXPENSE_CASH_FLOW_SPEC.md` | POS untuk session/cash drawer; Finance untuk jurnal |
| Metode pembayaran, split payment, gateway fee | `PAYMENT_METHOD_MASTERDATA_SPEC.md` | POS untuk checkout/offline; Finance Core untuk settlement/reconciliation |
| Pajak Sales/Purchase | `TAX_ENGINE_SPEC.md` | Product Category/Product untuk resolver; Finance untuk account/report |
| Purchase matching, receipt/invoice tolerance | `PURCHASE_MATCHING_TOLERANCE_SPEC.md` | Product/Stock dan POS untuk receipt; Finance untuk AP/invoice |
| UOM, berat, precision, valuation | `UOM_WEIGHT_VALUATION_SPEC.md` | Product/Stock; Purchase matching dan Finance bila ada nilai |
| Pricelist dan diskon | `SALES_PRICELIST_NOTES.md` | POS untuk Draft/checkout |
| Customer dan Customer Balance | `SALES_CUSTOMER_MASTERDATA_SPEC.md` | POS dan Finance boundary |
| Collection TEMPO dan Customer Statement | `COLLECTION_AND_CUSTOMER_STATEMENT_SPEC.md` | Customer Master, POS TEMPO, Finance AR/write-off |
| Ketul | `KETUL_WORKFLOW_NOTES.md` | Product/Stock, POS, Finance boundary |
| Finance Core, COA, jurnal, periode | `FINANCE_CORE_ACCOUNTING_SPEC.md` | `FINANCE_INTEGRATION_NOTES.md` untuk mapping source event |
| Selisih Setor Kas kurang/lebih | `DEPOSIT_VARIANCE_RESOLUTION_SPEC.md` | POS untuk dokumen Setor Kas; Finance Core untuk akun/jurnal |
| Koreksi nilai Debit/Credit Note | `DEBIT_CREDIT_NOTE_SPEC.md` | POS/Product untuk Return; Tax Engine dan Finance Core untuk posting |
| Transaction Category, system key, COA resolver | `TRANSACTION_CATEGORY_ACCOUNT_MAPPING_SPEC.md` | Finance Core dan setiap source module yang membuat journal |
| Bundle revenue, component allocation, margin | `BUNDLE_REVENUE_ALLOCATION_SPEC.md` | Product/Stock, POS, Pricelist, Tax, Debit/Credit Note |
| Finance report, cut-off, pending analysis | `FINANCE_REPORTING_AND_CUTOFF_SPEC.md` | Finance Core dan source module status/history |
| Dataset UAT Finance terkontrol | `runbooks/G6_PHASE7B_FINANCE_UAT_DATASET.md` | Product/Opening Stock/Adjustment dan controlled Finance queue harus sudah live |
| G6 Phase 8 operational HOLD preflight | `runbooks/G6_PHASE8_OPERATIONAL_HOLD_CONTRACT_PREFLIGHT.md` | SELECT-only audit sembilan kontrak sebelum Sale/Purchase/Expense/Cash journal posting dibuka |
| G6 Phase 8A Sale/Return posting preflight | `runbooks/G6_PHASE8A_SALE_RETURN_POSTING_PREFLIGHT.md` | Exact amount/account readiness sebelum dynamic Sale dan refund journal migration |
| Modal dan Aset | `CAPITAL_AND_ASSET_NOTES.md` | Finance saat fase detail dibuka |
| Role, tenant, RLS | `../KGS_BACKOFFICE_AUTH_FLOW_WORKFLOW.md`, `rls-access-matrix.md` | Multi-company docs/migration yang relevan |
| Role baseline + custom restriction per submodul | `ROLE_BASELINE_CUSTOM_PERMISSION_PLAN.md` | `rls-access-matrix.md`, navigation/API/RPC/RLS inventory aktual |
| ACP-1 access fingerprint | `ACP1_ACCESS_ACTION_BASELINE_MATRIX.md`, `runbooks/ACP1_ACCESS_COMPATIBILITY_PREFLIGHT.md` | SELECT-only diagnostic `../supabase/diagnostics/acp_phase1_access_compatibility_preflight.sql` |
| ACP-4 Inventory permission pilot preflight | `runbooks/ACP4_INVENTORY_PILOT_PREFLIGHT.md` | SELECT-only diagnostic `../supabase/diagnostics/acp_phase4_inventory_pilot_preflight.sql`; enforcement tetap tertutup sampai output direview |
| ACP-4A guarded Inventory master boundary | `runbooks/ACP4A_GUARDED_INVENTORY_MASTER_BOUNDARY.md` | Migration/RPC/postflight/behavior menutup direct browser write UOM, Warehouse, Store, dan Terminal tanpa membuka permission enforcement |
| ACP-4B Inventory Master enforcement preflight | `runbooks/ACP4B_INVENTORY_MASTER_ENFORCEMENT_PREFLIGHT.md` | SELECT-only diagnostic untuk navigation/API/RPC/direct-write cutover satu key `inventory.master_data` |
| ACP-4B Inventory Master enforcement rollout | `runbooks/ACP4B_INVENTORY_MASTER_ENFORCEMENT_ROLLOUT.md` | Satu key lengkap: guarded mutation, effective navigation/API, preset editor, postflight, behavior, dan multi-Company smoke |
| ACP-4C Product permission preflight | `runbooks/ACP4C_PRODUCT_PERMISSION_PREFLIGHT.md` | Diagnostic SELECT-only untuk Product+UOM, management/reference read split, import/export, API/RPC, history, dan tenant cutover |
| ACP-4C Product permission enforcement | `runbooks/ACP4C_PRODUCT_PERMISSION_ENFORCEMENT_ROLLOUT.md` | Product management/mutation/import/export lengkap tanpa memutus reference picker lintas modul |
| ACP-4D Stock read-model preflight | `runbooks/ACP4D_STOCK_READ_MODELS_PREFLIGHT.md` | Diagnostic SELECT-only untuk Stock Real, Kartu Stok, FIFO valuation, shared on-hand reference, export, RLS, dan rekonsiliasi sebelum enforcement |
| ACP-4D Stock read-model enforcement | `runbooks/ACP4D_STOCK_READ_MODEL_ENFORCEMENT_ROLLOUT.md` | Guarded composite Stock Real, Kartu Stok terpisah, export capability, server-side FIFO summary, compatibility consumer operasional, postflight dan behavior |
| ACP-4E Stock Transfer permission preflight | `runbooks/ACP4E_STOCK_TRANSFER_PERMISSION_PREFLIGHT.md` | Diagnostic SELECT-only untuk navigation/read/reference, Draft/Post/Cancel RPC, direct browser access, FIFO/Movement/idempotency, dan tenant cutover Transfer |
| ACP-4E Stock Transfer enforcement | `runbooks/ACP4E_STOCK_TRANSFER_PERMISSION_ENFORCEMENT_ROLLOUT.md` | Guarded composed read/reference, capability Create/Edit/Post/Cancel, browser table-read closure, postflight, behavior, dan smoke preset/two-Company |
| ACP-4F Stock Adjustment permission preflight | `runbooks/ACP4F_STOCK_ADJUSTMENT_PERMISSION_PREFLIGHT.md` | Diagnostic SELECT-only untuk read/reference, Draft/Post/Cancel, trusted Stock Opname path, FIFO/Movement, tenant, dan direct browser boundary |
| ACP-4F Stock Adjustment enforcement | `runbooks/ACP4F_STOCK_ADJUSTMENT_PERMISSION_ENFORCEMENT_ROLLOUT.md` | Guarded composed read/reference, capability Draft/Post/Cancel, trusted Opname core, direct table-read closure, postflight, regression, dan authenticated smoke |
| ACP-4G Stock Opname permission preflight | `runbooks/ACP4G_STOCK_OPNAME_PERMISSION_PREFLIGHT.md` | Diagnostic SELECT-only untuk pemisahan Backoffice/blind count, lifecycle, recount/supersede, trusted Adjustment core, composed read, tenant, dan capability cutover |
| ACP-4G Stock Opname enforcement | `runbooks/ACP4G_STOCK_OPNAME_PERMISSION_ENFORCEMENT_ROLLOUT.md` | Composed Backoffice report, restriction-aware blind count, capability Review/Post/Cancel, direct table-read closure, trusted Adjustment regression, dan two-Company smoke |
| ACP-4H Opening Stock permission preflight | `runbooks/ACP4H_OPENING_STOCK_PERMISSION_PREFLIGHT.md` | Diagnostic SELECT-only untuk role Draft/Post, composed read/reference, no-prior-Movement, zero-cost, idempotency, tenant, dan Stock–Movement–FIFO/Finance proof |
| ACP-4H Opening Stock enforcement | `runbooks/ACP4H_OPENING_STOCK_PERMISSION_ENFORCEMENT_ROLLOUT.md` | Capability Draft/Edit/Post, Store-scoped preparation, composed evidence/reference read, direct table closure, regression G3, dan two-Company smoke |
| ACP-4I Minimum Stock permission preflight | `runbooks/ACP4I_MINIMUM_STOCK_PERMISSION_PREFLIGHT.md` | Diagnostic SELECT-only untuk composed read/reference, Base-UOM threshold, mutation/import/export capability, tenant/audit, dan keputusan scope Store Manager |
| ACP-4I Minimum Stock enforcement | `runbooks/ACP4I_MINIMUM_STOCK_PERMISSION_ENFORCEMENT_ROLLOUT.md` | Composed setting/reference/balance read, Store-scoped Manage, capability-aware export/import, direct table closure, postflight, behavior, dan regression Phase-46 |
| ACP-5A Customer permission preflight | `runbooks/ACP5A_CUSTOMER_PERMISSION_PREFLIGHT.md` | Diagnostic SELECT-only untuk Customer/Category management, parent/Pricelist, POS quick-create, Finance balance, shared reference, import/export, tenant, dan direct browser boundary |
| ACP-5A Customer permission enforcement | `runbooks/ACP5A_CUSTOMER_PERMISSION_ENFORCEMENT_ROLLOUT.md` | Composed Customer workspace, guarded mutation/import/export, direct table closure, serta POS/Sales/Finance Customer references dengan authority terpisah |
| ACP-5B Supplier permission preflight | `runbooks/ACP5B_SUPPLIER_PERMISSION_PREFLIGHT.md` | Diagnostic SELECT-only untuk Supplier/Product-Supplier management, bank reference, Purchase/Finance/Product consumers, import/export, tenant, dan direct browser boundary |
| ACP-5B Supplier permission enforcement | `runbooks/ACP5B_SUPPLIER_PERMISSION_ENFORCEMENT_ROLLOUT.md` | Composed Supplier workspace, guarded mutation/import/export, direct table closure, serta Purchase/Finance/PWA reference RPC dengan authority terpisah |
| ACP-5C Supplier Order permission preflight | `runbooks/ACP5C_SUPPLIER_ORDER_PERMISSION_PREFLIGHT.md` | Diagnostic SELECT-only untuk workspace Supplier Order, Stock Request Cashier, Goods Receipt consumer, allocation/lifecycle/zero-effect, tenant, dan browser boundary |
| ACP-5C Supplier Order permission enforcement | `runbooks/ACP5C_SUPPLIER_ORDER_PERMISSION_ENFORCEMENT_ROLLOUT.md` | Composed Purchase workspace, capability-aware order action, narrow Cashier Request/Receipt references, direct table closure, postflight, behavior, dan regression |
| ACP-5D Purchase Return permission preflight | `runbooks/ACP5D_PURCHASE_RETURN_PERMISSION_PREFLIGHT.md` | Diagnostic SELECT-only untuk Backoffice review/post, Cashier open-session Draft, source Receipt/FIFO/AP, lifecycle/idempotency, tenant, dan browser boundary |
| ACP-5D Purchase Return permission enforcement | `runbooks/ACP5D_PURCHASE_RETURN_PERMISSION_ENFORCEMENT_ROLLOUT.md` | Composed Backoffice/PWA read split, capability Review/Post/Cancel, open-session Cashier Draft, direct table closure, postflight, behavior, dan regression |
| ACP-5E Sales Document permission preflight | `runbooks/ACP5E_SALES_DOCUMENT_PERMISSION_PREFLIGHT.md` | Diagnostic SELECT-only untuk Invoice/Surat Jalan list-detail-print-export, Delivery lifecycle, POS/Return/Finance authority split, tenant, snapshot, dan direct browser boundary |
| ACP-5E Sales Document permission enforcement | `runbooks/ACP5E_SALES_DOCUMENT_PERMISSION_ENFORCEMENT_ROLLOUT.md` | Composed Backoffice reads, VIEW/MANAGE/EXPORT guards, independent PWA posted-Invoice path, direct table closure, postflight, behavior, dan regression |
| ACP-5F Pricelist permission preflight | `runbooks/ACP5F_PRICELIST_PERMISSION_PREFLIGHT.md` | Diagnostic SELECT-only untuk Pricelist/rule/Store scope, Customer assignment split, POS online/offline consumer, resolver, export, tenant, snapshot, dan direct browser boundary |
| ACP-5F Pricelist permission enforcement | `runbooks/ACP5F_PRICELIST_PERMISSION_ENFORCEMENT_ROLLOUT.md` | Composed Backoffice read, guarded save/export, open-session POS reference, Offline/resolver preservation, legacy overload quarantine, direct table closure, postflight, behavior, dan regression |
| ACP-5G Bundle permission preflight | `runbooks/ACP5G_BUNDLE_PERMISSION_PREFLIGHT.md` | Diagnostic SELECT-only untuk atomic Bundle/composition, virtual stock, availability, POS component FIFO, Return allocation, tenant, dan direct browser boundary |
| ACP-5G Bundle permission enforcement | `runbooks/ACP5G_BUNDLE_PERMISSION_ENFORCEMENT_ROLLOUT.md` | Composed Backoffice read/reference, atomic VIEW/MANAGE guards, narrow availability, direct Bundle table closure, postflight, behavior, dan POS/Return regression |
| ACP-5H Sales Return permission preflight | `runbooks/ACP5H_SALES_RETURN_PERMISSION_PREFLIGHT.md` | Diagnostic SELECT-only untuk Backoffice review/post/cancel, PWA open-session Draft, refund/FIFO/Bundle/ongkir, Finance HOLD, tenant, dan direct browser boundary |
| ACP-5H Sales Return permission enforcement | `runbooks/ACP5H_SALES_RETURN_PERMISSION_ENFORCEMENT_ROLLOUT.md` | Composed Backoffice VIEW, guarded Post/Cancel, open-session PWA source/Draft, direct Return table closure, postflight, behavior, dan regression |
| ACP-6A Expense permission preflight | `runbooks/ACP6A_EXPENSE_PERMISSION_PREFLIGHT.md` | Diagnostic SELECT-only untuk lifecycle Expense, Category/policy, Backoffice/PWA channel split, drawer, settlement/return/additional, Finance HOLD, tenant, dan direct browser boundary |
| ACP-6A Expense permission enforcement | `runbooks/ACP6A_EXPENSE_PERMISSION_ENFORCEMENT.md` | Composed Backoffice capability, restriction-aware PWA session channel, private mutation core, dedicated-table read closure, postflight, behavior, dan smoke |
| ACP-6B Cash Deposit permission preflight | `runbooks/ACP6B_CASH_DEPOSIT_PERMISSION_PREFLIGHT.md` | Diagnostic SELECT-only untuk Backoffice review, Cashier CLOSED-session channel, multi-session allocation, variance exception, Finance HOLD, tenant, dan direct browser boundary |
| ACP-6B Cash Deposit permission enforcement | `runbooks/ACP6B_CASH_DEPOSIT_PERMISSION_ENFORCEMENT.md` | Composed Backoffice VIEW, restriction-aware Cashier channel, separate Deposit Variance reference, private mutation core, direct-table read closure, postflight, behavior, regression, dan smoke |
| ACP-6C Deposit Variance permission preflight | `runbooks/ACP6C_DEPOSIT_VARIANCE_PERMISSION_PREFLIGHT.md` | Diagnostic SELECT-only untuk investigation, responsible party, partial resolution, maker-checker, allocation/event/audit chain, Finance HOLD, linked Cash Deposit boundary, tenant, dan direct browser read |
| ACP-6C Deposit Variance permission enforcement | `runbooks/ACP6C_DEPOSIT_VARIANCE_PERMISSION_ENFORCEMENT.md` | Composed Backoffice VIEW, guarded MANAGE/APPROVE/REVIEW, private transaction cores, linked Deposit snapshot, direct-table closure, postflight, behavior, regression, dan smoke |
| ACP-6D Customer Balance permission preflight | `runbooks/ACP6D_CUSTOMER_BALANCE_PERMISSION_PREFLIGHT.md` | Diagnostic SELECT-only untuk ledger/cache, policy, koreksi maker-checker, POS consumer split, Customer boundary, tenant, event/audit, dan direct browser read |
| ACP-6D Customer Balance permission enforcement | `runbooks/ACP6D_CUSTOMER_BALANCE_PERMISSION_ENFORCEMENT.md` | Composed Backoffice VIEW, MANAGE/APPROVE/REVIEW/EXPORT guards, private proven cores, direct-table closure, POS boundary preservation, postflight, behavior, dan regression |
| ACP-6E Supplier Invoice permission preflight | `runbooks/ACP6E_SUPPLIER_INVOICE_PERMISSION_PREFLIGHT.md` | Diagnostic SELECT-only untuk invoice/matching/tolerance, maker-validator authority, Supplier Payment consumer boundary, tenant, event HOLD, dan direct browser read |
| ACP-6E Supplier Invoice permission enforcement | `runbooks/ACP6E_SUPPLIER_INVOICE_PERMISSION_ENFORCEMENT.md` | Composed Finance read, guarded Draft/Post/tolerance/export, narrow Payment/Return references, direct-table closure, postflight, behavior, dan G5 regressions |
| ACP-6F Supplier Payment permission preflight | `runbooks/ACP6F_SUPPLIER_PAYMENT_PERMISSION_PREFLIGHT.md` | Diagnostic SELECT-only untuk pembayaran AP, alokasi Invoice, source cash/bank account, Draft-only cancel, tenant/audit, optional export, dan Finance HOLD |
| ACP-6F Supplier Payment permission enforcement | `runbooks/ACP6F_SUPPLIER_PAYMENT_PERMISSION_ENFORCEMENT.md` | Composed Finance read, Draft/Edit/Post/export guards, source-account validation, Draft-only cancel, direct-table closure, postflight, behavior, dan G5 regression |
| ACP-6G Payment Method permission preflight | `runbooks/ACP6G_PAYMENT_METHOD_PERMISSION_PREFLIGHT.md` | Diagnostic SELECT-only untuk default/Store/route/fee, Account Function, metode sistem, snapshot Sale, POS/Expense consumer split, tenant/audit, export/import, dan browser boundary |
| ACP-6G Payment Method permission enforcement | `runbooks/ACP6G_PAYMENT_METHOD_PERMISSION_ENFORCEMENT.md` | Composed Backoffice read/export, guarded MANAGE, separate POS/Expense references, truthful audit backfill, dan direct-table closure tanpa membuka import/Jurnal |
| Review konflik lintas modul | `CROSS_MODULE_MD_REVIEW_2026-07-15.md` | Spesifikasi khusus jika perlu bukti detail |
| Review final mapping Finance | `FINANCE_MAPPING_REVIEW_2026-07-19.md` | Finance Core/Integration dan spesifikasi source module |
| Scope/index requirement POS v1 | `POS_V1_MVP_REQUIREMENT_INDEX.md` | Spesifikasi modul yang ditunjuk oleh ID requirement |
| Audit gap implementasi sebelum build | `PRE_BUILD_IMPLEMENTATION_GAP_AUDIT_2026-07-20.md` | File schema/RPC/API/PWA aktif; verifikasi live terpisah |
| Gate implementasi, UAT, rollout, rollback | `POS_V1_IMPLEMENTATION_GATES.md` | Index requirement dan audit gap terbaru |
| G0 schema baseline manual | `runbooks/G0_SCHEMA_BASELINE_RUNBOOK.md` | `../supabase/MIGRATION_MANIFEST.md` dan diagnostic read-only |
| G0 live baseline evidence | `audits/G0_LIVE_SCHEMA_BASELINE_2026-07-20.md` | G0 closed; fingerprint catalog sudah direkonsiliasi |
| G1 fase 1 rollout | `runbooks/G1_PHASE1_SECURITY_FEATURE_ROLLOUT.md` | Migration security/feature foundation + postflight |
| G1 fase 1 rollout evidence | `audits/G1_PHASE1_ROLLOUT_2026-07-20.md` | Complete; DB dan app smoke PASS |
| G1 fase 2 core tenant rollout | `runbooks/G1_PHASE2_CORE_TENANT_ROLLOUT.md` | Composite FK untuk core master dan inventory |
| G1 fase 2 rollout evidence | `audits/G1_PHASE2_CORE_TENANT_ROLLOUT_2026-07-20.md` | Complete; DB dan local app smoke dikonfirmasi PASS |
| G1 fase 2 PostgREST compatibility | `audits/G1_PHASE2_POSTGREST_COMPATIBILITY_2026-07-20.md` | Relationship hint Product → Stock → Warehouse |
| G1 fase 3 transaction tenant rollout | `runbooks/G1_PHASE3_TRANSACTION_TENANT_ROLLOUT.md` | Composite FK untuk Session, Sales, Payment, dan Purchase |
| G1 fase 3 rollout evidence | `audits/G1_PHASE3_TRANSACTION_TENANT_ROLLOUT_2026-07-20.md` | Complete; transaction tenant checks dikonfirmasi PASS |
| G1 fase 4 active Company context rollout | `runbooks/G1_PHASE4_ACTIVE_COMPANY_CONTEXT_ROLLOUT.md` | Membership vocabulary dan auditable server-side Company context |
| G1 fase 4 rollout evidence | `audits/G1_PHASE4_ACTIVE_COMPANY_CONTEXT_ROLLOUT_2026-07-20.md` | Complete; active Company KGS terverifikasi melalui `BACKOFFICE_INIT` |
| G1 fase 5A core role/RLS rollout | `runbooks/G1_PHASE5A_CORE_ROLE_RLS_ROLLOUT.md` | Canonical helper dan policy Profile/Company/Store/POS/Warehouse |
| G1 fase 5A rollout evidence | `audits/G1_PHASE5A_CORE_ROLE_RLS_ROLLOUT_2026-07-20.md` | Complete; DB test dan local Backoffice smoke dikonfirmasi aman |
| G1 fase 5B catalog/inventory RLS rollout | `runbooks/G1_PHASE5B_CATALOG_INVENTORY_RLS_ROLLOUT.md` | Active-Company policy Product/UOM/Customer dan read-only Stock/FIFO; Pricelist canonical ditunda ke G2 |
| G1 fase 5B rollout evidence | `audits/G1_PHASE5B_CATALOG_INVENTORY_RLS_ROLLOUT_2026-07-21.md` | Complete; DB test dan local Backoffice smoke dikonfirmasi aman |
| G1 fase 5C transaction RLS rollout | `runbooks/G1_PHASE5C_TRANSACTION_RLS_ROLLOUT.md` | Scoped Session/Sales/Payment/Purchase reads dan guarded checkout RPC |
| G1 fase 5C rollout evidence | `audits/G1_PHASE5C_TRANSACTION_RLS_ROLLOUT_2026-07-21.md` | Complete; DB test, POS, dan Backoffice dikonfirmasi aman |
| G1 fase 5D Finance RLS rollout | `runbooks/G1_PHASE5D_FINANCE_RLS_ROLLOUT.md` | Scoped Expense/Setoran reads, immutable Event/Jurnal/Reconciliation, service-role worker |
| G1 fase 5D rollout evidence | `audits/G1_PHASE5D_FINANCE_RLS_ROLLOUT_2026-07-21.md` | Complete; DB test dan local POS/Backoffice smoke dikonfirmasi aman |
| G1 fase 5E inventory-operation RLS rollout | `runbooks/G1_PHASE5E_INVENTORY_OPERATION_RLS_ROLLOUT.md` | Tenant-safe FIFO/Opname/Adjustment/Movement reads dan server-only mutation boundary |
| G1 fase 5E rollout evidence | `audits/G1_PHASE5E_INVENTORY_OPERATION_RLS_ROLLOUT_2026-07-21.md` | Complete; DB test dan local smoke dikonfirmasi aman |
| G1 security closure preflight | `../supabase/diagnostics/g1_security_closure_preflight.sql` | Audit final 35 tabel, RLS, grants, function safety, active Company, dan ledger migration |
| G1 security closure runbook | `runbooks/G1_SECURITY_CLOSURE.md` | Integrated negative-access test dan local smoke sebelum menutup G1 |
| G1 security closure evidence | `audits/G1_SECURITY_CLOSURE_2026-07-21.md` | Complete; 15/15 preflight PASS, integrated test PASS, dan seluruh menu Backoffice lokal aman |
| G6 corrective phase 1 routine quarantine | `runbooks/G6_PHASE1_FINANCE_ROUTINE_QUARANTINE_ROLLOUT.md` | Privilege-only forward fix untuk menutup routine rejected/legacy dari browser tanpa mutation Finance |
| G6 corrective phase 2 journal preflight | `runbooks/G6_PHASE2_JOURNAL_FOUNDATION_PREFLIGHT.md` | SELECT-only live-state audit period/journal object, topology legacy, privilege, RLS, constraint, dan HOLD-event inventory |
| G6 corrective phase 2 journal foundation | `runbooks/G6_PHASE2_TENANT_SAFE_JOURNAL_FOUNDATION_ROLLOUT.md` | Additive Accounting Period/journal header-line-audit, tenant FK, balance, immutable history, guarded lifecycle, dan no-event-posting boundary |
| G6 corrective phase 3 posting mapping preflight | `runbooks/G6_PHASE3_VERSIONED_POSTING_MAPPING_PREFLIGHT.md` | SELECT-only inventory source amount key, required Account Function, rule/fallback ambiguity, compatible COA, dan HOLD-event mapping scope |
| G6 corrective phase 3 imported COA ownership fix | `runbooks/G6_PHASE3_IMPORTED_COA_OWNERSHIP_FIX.md` | Menjadikan duplicate COA hasil import sebagai Company-owned, mempertahankan seed canonical dan histori, serta mencegah duplicate system ownership baru |
| G6 corrective phase 3 posting mapping rollout | `runbooks/G6_PHASE3_VERSIONED_POSTING_MAPPING_ROLLOUT.md` | Canonical system-owned atau sole explicit function-account provisioning serta guarded versioned/effective/approved rule-set tanpa event processing |
| G6 corrective phase 4 single-event posting preflight | `runbooks/G6_PHASE4_SINGLE_EVENT_POSTING_PREFLIGHT.md` | SELECT-only audit approved expression rule, event/source contract, Accounting Period, idempotency, journal balance, exception, dan browser boundary sebelum atomic posting dibuat |
| G6 corrective phase 4 atomic single-event posting rollout | `runbooks/G6_PHASE4_ATOMIC_SINGLE_EVENT_POSTING_ROLLOUT.md` | Source-validated STOCK_OPENING resolver, approved account/expression rule, period-safe balanced journal, exact idempotency, exception isolation, postflight, dan rollback-safe behavior tanpa memproses queue HOLD |
| G2 fase 1 master-data preflight | `../supabase/diagnostics/g2_phase1_master_data_preflight.sql` | SELECT-only audit untuk backfill Product Category, UOM, Product-UOM, dan Warehouse legacy |
| G2 fase 1 preflight evidence | `audits/G2_PHASE1_MASTER_DATA_PREFLIGHT_2026-07-21.md` | Live master surface kosong dan bersih; expand migration tidak memerlukan business-row backfill |
| G2 fase 1 master-data rollout | `runbooks/G2_PHASE1_MASTER_DATA_FOUNDATION_ROLLOUT.md` | Additive Category/Product-UOM foundation, master versioning, RLS, dan historical UOM guard |
| G2 fase 1 postflight | `../supabase/diagnostics/g2_phase1_master_data_postflight.sql` | Verifikasi tabel, kolom, FK, trigger, RLS, privilege, compatibility, dan ledger |
| G2 fase 1 rollout evidence | `audits/G2_PHASE1_MASTER_DATA_ROLLOUT_2026-07-21.md` | Complete; migration, postflight, dan behavioral test dikonfirmasi berhasil |
| G2 fase 2 canonical master API | `runbooks/G2_PHASE2_MASTER_API_ROLLOUT.md` | Authenticated active-Company API Category/UOM/Warehouse dengan RLS dan optimistic concurrency |
| G2 fase 2 API evidence | `audits/G2_PHASE2_MASTER_API_2026-07-21.md` | Complete; lint/build dan local authenticated smoke dikonfirmasi aman |
| G2 fase 3 canonical master UI | `runbooks/G2_PHASE3_MASTER_UI_ROLLOUT.md` | Complete; menu/list/form serta local create/edit Category, UOM, dan Warehouse dikonfirmasi aman |
| G2 fase 4 Product CRUD preflight | `runbooks/G2_PHASE4_PRODUCT_CRUD_PREFLIGHT.md` | SELECT-only readiness audit untuk atomic Product + Product-UOM dan compatibility UI lama |
| G2 fase 4 atomic Product rollout | `runbooks/G2_PHASE4_ATOMIC_PRODUCT_CRUD_ROLLOUT.md` | Guarded RPC, audit, versioning, privilege closure, postflight, dan behavioral test |
| G2 fase 5 canonical Product API/UI | `runbooks/G2_PHASE5_CANONICAL_PRODUCT_UI_ROLLOUT.md` | Active-Company Product list/form dan atomic Product-UOM create/update untuk local authenticated smoke |
| G2 fase 6 Supplier preflight | `runbooks/G2_PHASE6_SUPPLIER_MASTER_PREFLIGHT.md` | SELECT-only inventory Supplier legacy dan kesiapan relasi Product-Supplier sebelum schema canonical |
| G2 fase 6 Supplier rollout | `runbooks/G2_PHASE6_SUPPLIER_FOUNDATION_ROLLOUT.md` | Supplier/Product-Supplier schema, tenant FK, preferred uniqueness, audited RPC, RLS, postflight, dan behavioral test |
| G2 fase 7 Supplier API/UI | `runbooks/G2_PHASE7_SUPPLIER_API_UI_ROLLOUT.md` | Backoffice Supplier dan relasi Product-Supplier-UOM melalui guarded RPC serta smoke test tanpa Purchase/stock cutover |
| G2 fase 8 Customer preflight | `runbooks/G2_PHASE8_CUSTOMER_MASTER_PREFLIGHT.md` | SELECT-only audit Customer/Walk-In/category readiness, normalized duplicates, balance risk, dan browser privilege sebelum canonical Customer foundation |
| G2 fase 8 Customer foundation | `runbooks/G2_PHASE8_CUSTOMER_FOUNDATION_ROLLOUT.md` | Migration, postflight, test, Walk-In system, guarded RPC, dan database evidence Customer canonical |
| G2 fase 9 Customer API/UI | `runbooks/G2_PHASE9_CUSTOMER_API_UI_ROLLOUT.md` | Smoke test Backoffice Customer/Category canonical, role boundary, dan saldo read-only |
| G2 fase 10 Customer grouping/UX | `runbooks/G2_PHASE10_CUSTOMER_GROUPING_UX_ROLLOUT.md` | Customer induk-cabang satu tingkat, uniqueness normalized, nama UOM user-facing, dan modal Escape |
| G2 fase 11 Pricelist preflight | `runbooks/G2_PHASE11_PRICELIST_PREFLIGHT.md` | SELECT-only audit Product-UOM sale price, Customer/grouping, Sales history, snapshot pricing, dan Global default scope |
| G2 fase 12 Pricelist foundation | `runbooks/G2_PHASE12_PRICELIST_FOUNDATION_ROLLOUT.md` | Global/Customer Pricelist, Store assignment, versioned Product-UOM rules, audit, RLS, dan nullable Sales pricing snapshot tanpa checkout cutover |
| G2 fase 13 Pricelist API/UI | `runbooks/G2_PHASE13_PRICELIST_API_UI_ROLLOUT.md` | Backoffice Global/Customer Pricelist melalui guarded RPC, nama Product/UOM/Customer/Store user-facing, tier Global, dan smoke tanpa resolver checkout |
| G2 fase 13 Pricelist default guard | `runbooks/G2_PHASE13_PRICELIST_DEFAULT_GUARD_ROLLOUT.md` | Forward-only exact-one Global default invariant, atomic default handover, audit, postflight, dan behavioral test sebelum UI smoke |
| G2 fase 13 reusable Customer Pricelist preflight | `runbooks/G2_PHASE13_PRICELIST_CUSTOMER_ASSIGNMENT_PREFLIGHT.md` | SELECT-only audit untuk memindahkan assignment Pricelist dari header ke Customer agar satu Pricelist dapat digunakan banyak Customer |
| G2 fase 13 reusable Customer Pricelist rollout | `runbooks/G2_PHASE13_REUSABLE_CUSTOMER_PRICELIST_ROLLOUT.md` | Forward migration, guarded RPC, Customer assignment UI, postflight, dan behavioral test tanpa checkout cutover |
| G2 fase 14 Payment Method preflight | `runbooks/G2_PHASE14_PAYMENT_METHOD_PREFLIGHT.md` | SELECT-only audit legacy tender/history, canonical master dan snapshot gap, Store assignment, serta default provisioning tanpa checkout cutover |
| G2 fase 14 Payment Method foundation rollout | `runbooks/G2_PHASE14_PAYMENT_METHOD_FOUNDATION_ROLLOUT.md` | Master Payment Method tenant-scoped, default Tunai, Store assignment, fee, audit/versioning, guarded RPC, dan nullable Sales Payment snapshot tanpa checkout cutover |
| G2 fase 15 Payment Method API/UI smoke | `runbooks/G2_PHASE15_PAYMENT_METHOD_API_UI_ROLLOUT.md` | Guarded API dan Backoffice form/list untuk nama metode, Store scope, proof, settlement route, fee, default, serta lifecycle tanpa checkout cutover |
| G2 fase 16 Finance master preflight | `runbooks/G2_PHASE16_FINANCE_MASTER_PREFLIGHT.md` | SELECT-only audit Transaction Category, minimum COA, legacy Expense category, journal identity/balance, Payment account function, dan schema snapshot tanpa mengaktifkan Finance posting |
| G2 fase 16 Finance master foundation | `runbooks/G2_PHASE16_FINANCE_MASTER_FOUNDATION_ROLLOUT.md` | Registry System Event/Account Function, minimum tenant COA, Transaction Category, versioned mapping, exception queue, audit, dan nullable Event/Journal snapshot tanpa mengaktifkan posting |
| G2 fase 17 Finance master API/UI | `runbooks/G2_PHASE17_FINANCE_MASTER_API_UI_ROLLOUT.md` | Guarded Kategori Transaksi dan versioned account mapping, COA read-only, user-facing names, Escape modal, dan smoke tanpa mengaktifkan posting |
| G2 fase 18 required Transaction Categories | `runbooks/G2_PHASE18_REQUIRED_TRANSACTION_CATEGORIES_ROLLOUT.md` | Preflight, 26 kategori bawaan wajib per Company, immutable event/status guard, postflight/test, dan UI learning guide tanpa account mapping atau journal |
| G2 fase 19 Finance history trigger fix | `runbooks/G2_PHASE19_FINANCE_HISTORY_TRIGGER_FIX_ROLLOUT.md` | Forward fix PostgreSQL 42703 dengan table-first trigger branch, 5-row postflight, dan regression test tanpa mengubah data/mapping/jurnal |
| G2 fase 20 COA/fallback preflight | `runbooks/G2_PHASE20_COA_FALLBACK_PREFLIGHT.md` | SELECT-only audit COA identity/hierarchy/history, compatible account candidates, explicit fallback, unresolved required function, RPC state, dan browser privilege |
| G2 fase 20 guarded COA/fallback rollout | `runbooks/G2_PHASE20_GUARDED_COA_FALLBACK_ROLLOUT.md` | Guarded hierarchical COA add/edit/lifecycle, explicit versioned Company fallback, API/UI, postflight, dan behavioral test tanpa Finance posting |
| G2 fase 21 Tax master preflight | `runbooks/G2_PHASE21_TAX_MASTER_PREFLIGHT.md` | SELECT-only audit entitlement Sales/Purchase, Tax COA, Product/Category assignment, transaction history, dan snapshot gap tanpa kalkulasi atau posting |
| G2 fase 22 Tax master foundation | `runbooks/G2_PHASE22_TAX_MASTER_FOUNDATION_ROLLOUT.md` | Effective-dated Sales/Purchase Tax master, nullable assignments/snapshots, guarded RPC/RLS/audit, postflight/test tanpa mengaktifkan kalkulasi atau posting |
| G2 fase 23 Tax master API/UI | `runbooks/G2_PHASE23_TAX_MASTER_API_UI_ROLLOUT.md` | Guarded Tax Rule list/form, entitlement visibility, effective versioning, akun Tax user-facing, dan Escape modal tanpa assignment/resolver/kalkulasi |
| G2 fase 24 Module Settings API/UI | `runbooks/G2_PHASE24_MODULE_SETTINGS_API_UI_ROLLOUT.md` | Super Admin Company entitlement per modul melalui guarded RPC/audit, confirmation, dan Escape modal; konfigurasi detail tetap di menu modul |
| G2 fase 25 role-aware launcher/shell | `runbooks/G2_PHASE25_ROLE_AWARE_APP_LAUNCHER_SHELL.md` | Launcher Inventory/Kontak/Sales/Finance/Platform; Payment/Tax di Finance; role visibility dan sidebar fast-link scroll independen |
| G2 fase 26 Tax assignment preflight | `runbooks/G2_PHASE26_TAX_ASSIGNMENT_PREFLIGHT.md` | SELECT-only audit Tax entitlement/rule/current version, Category/Product assignment, override redundancy, RPC, dan direct-write boundary |
| G2 fase 26 guarded Tax assignment | `runbooks/G2_PHASE26_GUARDED_TAX_ASSIGNMENT_ROLLOUT.md` | Optimistic Category/Product assignment RPC, effective-version/entitlement guard, audit, atomic Product-UOM-Tax overload, postflight, dan test tanpa resolver |
| G2 fase 27 Tax assignment API/UI | `runbooks/G2_PHASE27_TAX_ASSIGNMENT_API_UI_ROLLOUT.md` | Entitlement-aware Category default dan Product inheritance/override memakai nama Tax Rule; smoke master-only tanpa calculation |
| G2 fase 28 Tax resolver/snapshot preflight | `runbooks/G2_PHASE28_TAX_RESOLVER_SNAPSHOT_PREFLIGHT.md` | SELECT-only audit Product override → Category default → no tax, current version/account, transaction snapshot, dan checkout legacy sebelum resolver server-side |
| G2 fase 28 private Tax resolver/calculator | `runbooks/G2_PHASE28_TAX_RESOLVER_CALCULATOR_ROLLOUT.md` | Effective-dated private resolver dan deterministic PER_LINE/PER_DOCUMENT calculator tanpa checkout/Purchase/journal cutover |
| G2 fase 29 Master Import/Export preflight | `runbooks/G2_PHASE29_IMPORT_FRAMEWORK_PREFLIGHT.md` | SELECT-only audit ambiguity master, Product-UOM group, protected history, Opening Stock eligibility, dan import legacy sebelum staging canonical |
| G2 fase 30 Master Import staging foundation | `runbooks/G2_PHASE30_MASTER_IMPORT_STAGING_FOUNDATION_ROLLOUT.md` | Tenant-scoped idempotent job/row/event staging untuk master non-stock; legacy Product+stock import dikarantina; validation/commit deferred |
| G2 fase 31 Master Import identity validator | `runbooks/G2_PHASE31_MASTER_IMPORT_IDENTITY_VALIDATOR_ROLLOUT.md` | Dry-run tenant-safe ID/nama untuk Category/UOM/Warehouse/Supplier, preview CREATE/UPDATE/SKIP/ERROR, diff/warning, duplicate file, tanpa commit |
| G2 fase 32 Master Import business validator | `runbooks/G2_PHASE32_MASTER_IMPORT_BUSINESS_VALIDATOR_ROLLOUT.md` | Field UOM/Gudang/Supplier/Kategori disamakan dengan manual CRUD, Store tenant-safe, lokasi Gudang opsional, preview-only |
| G2 fase 33 Master Import partial commit | `runbooks/G2_PHASE33_MASTER_IMPORT_PARTIAL_COMMIT_ROLLOUT.md` | Explicit update confirmation, optimistic master version, per-row partial success, retry idempotent, audit; Product/stock excluded |
| G2 fase 34 Master Import API/UI | `runbooks/G2_PHASE34_MASTER_IMPORT_API_UI_ROLLOUT.md` | Owner/Admin CSV mapping, preview, explicit UPDATE confirmation, partial result, history, error download, template/export untuk 4 master non-stock |
| G2 fase 35 full Master Import preflight | `runbooks/G2_PHASE35_FULL_MASTER_IMPORT_PREFLIGHT.md` | SELECT-only audit sebelum memperluas import ke seluruh canonical master yang user dapat buat |
| G2 fase 36 automatic master code preflight | `runbooks/G2_PHASE36_AUTOMATIC_MASTER_CODE_PREFLIGHT.md` | SELECT-only audit kode teknis otomatis/immutable untuk delapan master sebelum full-import migration |
| G2 fase 36 automatic master code rollout | `runbooks/G2_PHASE36_AUTOMATIC_MASTER_CODES_ROLLOUT.md` | Atomic tenant/entity counter, explicit-code reservation compatibility, immutable guard, wrapper RPC, postflight, dan behavioral test |
| G2 fase 37 automatic master code UI cutover | `runbooks/G2_PHASE37_AUTOMATIC_MASTER_CODE_UI_CUTOVER.md` | Form/list berbasis nama dan API tanpa parameter kode teknis; CSV existing tetap kompatibel sampai full-import gate |
| G2 fase 38 code-less simple master import | `runbooks/G2_PHASE38_CODELESS_MASTER_IMPORT_ROLLOUT.md` | Validator compatibility tanpa kolom kode untuk Category/UOM/Warehouse/Supplier; CSV lama tetap didukung sebelum full expansion |
| G2 fase 39 code-less Import UI cutover | `runbooks/G2_PHASE39_CODELESS_MASTER_IMPORT_UI_CUTOVER.md` | Template create, preview, export update, dan referensi Toko user-facing tanpa kode teknis empat master |
| G2 fase 40 remaining simple master import preflight | `runbooks/G2_PHASE40_SIMPLE_MASTER_IMPORT_PREFLIGHT.md` | SELECT-only audit Customer Category, COA, Transaction Category, system-owned rows, hierarchy/history, guarded RPC, dan import job aktif |
| G2 fase 40 remaining simple master import rollout | `runbooks/G2_PHASE40_REMAINING_SIMPLE_MASTER_IMPORT_ROLLOUT.md` | Additive job type, preview, guarded partial commit, system-row protection, postflight, dan test untuk Customer Category/COA/Transaction Category |
| G2 fase 40 COA parent UUID forward fix | `runbooks/G2_PHASE40_COA_PARENT_UUID_AGGREGATE_FIX.md` | Forward-only perbaikan PostgreSQL `min(uuid)` pada preview parent COA tanpa mengedit migration applied |
| G2 fase 41 remaining simple master Import UI | `runbooks/G2_PHASE41_REMAINING_SIMPLE_MASTER_IMPORT_UI.md` | Template/export/mapping/preview untuk Customer Category, COA, dan Transaction Category dengan system rows export-only |
| G2 fase 42 grouped Product Import preflight | `runbooks/G2_PHASE42_GROUPED_PRODUCT_IMPORT_PREFLIGHT.md` | SELECT-only audit Product + seluruh Product-UOM sebagai atomic group, reference, Tax, history guard, dan import-job readiness |
| G2 fase 42 grouped Product Import rollout | `runbooks/G2_PHASE42_GROUPED_PRODUCT_IMPORT_ROLLOUT.md` | Grouped preview, guarded atomic commit, history lock, postflight/test, dan regression simple-master tanpa stock mutation |
| G2 fase 42 Product Import COMPLETE event fix | `runbooks/G2_PHASE42_PRODUCT_IMPORT_COMPLETE_EVENT_FIX.md` | Forward-only koreksi audit event `COMMIT` menjadi canonical `COMPLETE`, 4-check postflight, dan rerun behavioral test |
| G2 fase 43 grouped Product Import UI | `runbooks/G2_PHASE43_GROUPED_PRODUCT_IMPORT_UI.md` | Template/export fixed Product + UOM, preview per `product_key`, nama master user-facing, dan stock-neutral smoke |
| G2 fase 44 Product-Supplier Import preflight | `runbooks/G2_PHASE44_PRODUCT_SUPPLIER_IMPORT_PREFLIGHT.md` | SELECT-only audit Product/Supplier/UOM pembelian, preferred uniqueness, guarded RPC, existing relation, dan import-job readiness |
| G2 fase 44 Product-Supplier Import rollout | `runbooks/G2_PHASE44_PRODUCT_SUPPLIER_IMPORT_ROLLOUT.md` | Guarded preview/partial commit, preferred switch ordering, audit/idempotency, postflight/test/regression, dan no-stock boundary |
| G2 fase 45 Product-Supplier Import UI | `runbooks/G2_PHASE45_PRODUCT_SUPPLIER_IMPORT_UI.md` | Template/export fixed, preview tanpa UUID, preferred-switch guidance, server error labels, dan authenticated smoke checklist |
| G2 fase 46 Minimum Stock Produk–Gudang preflight | `runbooks/G2_PHASE46_PRODUCT_WAREHOUSE_MINIMUM_STOCK_PREFLIGHT.md` | SELECT-only audit pasangan eligible, base UOM, saldo/movement, referensi import, privilege, dan schema konfigurasi terpisah dari stock balance |
| G2 fase 46 Minimum Stock Produk–Gudang rollout | `runbooks/G2_PHASE46_PRODUCT_WAREHOUSE_MINIMUM_STOCK_ROLLOUT.md` | Settings/audit tenant-scoped, guarded optimistic RPC, fixed CSV import, 12-check postflight, behavioral/regression, dan no-stock/no-request boundary |
| G2 fase 47 Minimum Stock API/UI | `runbooks/G2_PHASE47_MINIMUM_STOCK_API_UI.md` | Halaman konfigurasi Base-UOM threshold, guarded API, fixed template/export/preview, dan authenticated no-stock-mutation smoke |
| G3 fase 1 Opening Stock preflight | `runbooks/G3_PHASE1_OPENING_STOCK_PREFLIGHT.md` | SELECT-only audit saldo/movement/FIFO, pasangan Product-Gudang eligible, Base UOM, Finance mapping, enum, dan schema sebelum posting stok aktual dibuka |
| G3 fase 1 Opening Stock rollout | `runbooks/G3_PHASE1_OPENING_STOCK_FOUNDATION_ROLLOUT.md` | Draft/Posted, guarded posting, atomic movement/saldo/FIFO/event/audit, idempotency, postflight, behavior, regression, dan forward-fix boundary |
| G3 fase 2 Opening Stock API/UI | `runbooks/G3_PHASE2_OPENING_STOCK_API_UI.md` | Guarded Draft/Posting Backoffice, nama Product/Gudang/UOM, bukti stok aktual/movement/FIFO, role boundary, Escape modal, dan authenticated smoke |
| G3 fase 3 Stock Real API/UI | `runbooks/G3_PHASE3_STOCK_REAL_API_UI.md` | Read-only On Hand/Available, FIFO valuation, last movement, Gudang/minimum filter, serta explicit G4/G5 deferred boundary |
| G3 fase 4 Stock Movement preflight | `runbooks/G3_PHASE4_STOCK_MOVEMENT_PREFLIGHT.md` | SELECT-only audit ledger shape/source/tenant/balance/Opening coverage, missing audit snapshot, enum readiness, dan browser write boundary |
| G3 fase 4 canonical Stock Movement rollout | `runbooks/G3_PHASE4_CANONICAL_STOCK_MOVEMENT_ROLLOUT.md` | Additive snapshots, Opening backfill/enrichment, immutable ledger, source-line uniqueness, postflight, behavior, dan regression |
| G3 fase 5 Stock Movement API/UI | `runbooks/G3_PHASE5_STOCK_MOVEMENT_API_UI.md` | Read-only Kartu Stok tenant-scoped dengan snapshot Base UOM/saldo, sumber, actor aman, filter, dan no-mutation boundary |
| G3 fase 6 Stock Transfer preflight | `runbooks/G3_PHASE6_STOCK_TRANSFER_PREFLIGHT.md` | Audit SELECT-only legacy RPC, transfer-pair history, canonical snapshot, saldo/FIFO, tenant, Finance category, privilege, dan missing document schema |
| G3 fase 6 Stock Transfer foundation | `runbooks/G3_PHASE6_STOCK_TRANSFER_FOUNDATION_ROLLOUT.md` | Draft/Posted/Canceled document, atomic balance/FIFO relocation, paired movement, role/idempotency/audit, postflight, behavior, dan regression |
| G3 fase 7 Stock Transfer API/UI | `runbooks/G3_PHASE7_STOCK_TRANSFER_API_UI.md` | Guarded create/edit/post/cancel, saldo/FIFO proof, role-aware Inventory UI, Kartu Stok source number, dan authenticated smoke |
| G3 fase 8 Stock Adjustment preflight | `runbooks/G3_PHASE8_STOCK_ADJUSTMENT_PREFLIGHT.md` | Audit SELECT-only legacy Adjustment, reason backfill, balance/FIFO, Base UOM, Finance readiness, privilege, dan gap canonical document |
| G3 fase 8 Stock Adjustment foundation | `runbooks/G3_PHASE8_STOCK_ADJUSTMENT_FOUNDATION_ROLLOUT.md` | Final physical quantity, reusable reason, Draft/Posted/Canceled, FIFO gain/loss, immutable Movement, Finance HOLD, role/idempotency/audit, postflight dan behavior |
| G3 fase 9 Stock Adjustment API/UI | `runbooks/G3_PHASE9_STOCK_ADJUSTMENT_API_UI.md` | Guarded final-quantity form, direction-aware reason, gain-cost override, Draft/Post/Cancel, FIFO/value proof, Kartu Stok source, Escape, dan authenticated smoke |
| G3 fase 10 Stock Opname preflight | `runbooks/G3_PHASE10_STOCK_OPNAME_PREFLIGHT.md` | Audit SELECT-only legacy Opname, overlap/supersede, Adjustment linkage, balance/FIFO, movement watermark, blind-count channel, privilege, dan gap canonical schema |
| G3 fase 10 Stock Opname foundation | `runbooks/G3_PHASE10_STOCK_OPNAME_FOUNDATION_ROLLOUT.md` | Blind-safe count RPC, nonblocking movement reconciliation, recount attempts, per-line supersede, atomic canonical Adjustment posting, role/idempotency/audit, postflight dan behavior |
| G3 fase 11 Stock Opname Backoffice | `runbooks/G3_PHASE11_STOCK_OPNAME_BACKOFFICE_API_UI.md` | Tenant-scoped report/review, attempt timeline, Adjustment proof, guarded recount/post/cancel, role boundary, Escape modal, dan batas POS blind count G4 |
| G3 fase 12 Bundle foundation preflight | `runbooks/G3_PHASE12_BUNDLE_FOUNDATION_PREFLIGHT.md` | Audit SELECT-only composition legacy, nested/self component, canonical UOM, virtual-stock invariant, browser privilege, schema/RPC gap, dan boundary checkout G4 |
| G3 fase 12 Bundle foundation rollout | `runbooks/G3_PHASE12_BUNDLE_FOUNDATION_ROLLOUT.md` | Atomic Bundle Product+composition, derived weight, immutable type, virtual-stock guard, audit/version, private expansion, reviewer availability, postflight dan behavior |
| G3 fase 13 Bundle master API/UI | `runbooks/G3_PHASE13_BUNDLE_MASTER_API_UI.md` | Guarded create/edit, komponen Product/UOM user-facing, harga final, derived weight, availability per Gudang, dan smoke boundary tanpa checkout |
| G3 fase 14 inventory-core exit/stress preflight | `runbooks/G3_PHASE14_INVENTORY_CORE_EXIT_PREFLIGHT.md` | Rekonsiliasi saldo–Movement–FIFO, source coverage, Bundle virtual, browser boundary, fixture stress, dan pemisahan coverage G4/G5 |
| G3 fase 15 inventory-core stress behavior | `runbooks/G3_PHASE15_INVENTORY_CORE_STRESS_BEHAVIOR.md` | Rollback-safe two-layer FIFO, retry idempotent, repeated Transfer contention, Adjustment gain, rekonsiliasi tiga arah, Bundle virtual, dan explicit non-concurrent boundary |
| G4 fase 1 POS checkout readiness preflight | `runbooks/G4_PHASE1_POS_CHECKOUT_READINESS_PREFLIGHT.md` | SELECT-only dependency/config/history/schema/RPC audit sebelum canonical Session, server pricing, Draft/Post Sale, FIFO/Bundle deduction, dan offline idempotency dibuka |
| G4 fase 2 Cashier Session foundation | `runbooks/G4_PHASE2_CASHIER_SESSION_FOUNDATION_ROLLOUT.md` | Guarded one-open Session, cash actual manual, opening/closing stock snapshot, optimistic version, idempotent retry, RLS/audit, dan explicit no-checkout boundary |
| G4 fase 3 Atomic Sale runtime preflight | `runbooks/G4_PHASE3_ATOMIC_SALE_RUNTIME_PREFLIGHT.md` | SELECT-only audit Session, legacy authority, pricing/payment/tax, Product-UOM/Bundle, Stock–Movement–FIFO, Finance category, schema snapshot, allocation, dan Draft/Post RPC gap |
| G4 fase 4 Atomic Sale runtime rollout | `runbooks/G4_PHASE4_ATOMIC_SALE_RUNTIME_ROLLOUT.md` | Server pricing, side-effect-free Draft, shortage contract, atomic FIFO/Bundle stock posting, Payment/Tax/rounding snapshots, receipt, Finance HOLD, idempotency, dan legacy checkout retirement |
| G4 fase 5 POS online integration smoke | `runbooks/G4_PHASE5_POS_ONLINE_INTEGRATION_SMOKE.md` | Login/context, Cashier Session, real Product-UOM/Customer/Payment, canonical Draft/Post, shortage, receipt snapshot, explicit offline block, dan authenticated smoke |
| G4 fase 5 Cashier role inheritance fix | `runbooks/G4_PHASE5_CASHIER_ROLE_INHERITANCE_FIX.md` | Forward fix Super Admin/Company Owner/Admin inheritance, ordinary Cashier Store assignment, postflight, behavior, regression, dan smoke ulang |
| G4 fase 5 Store Manager POS access fix | `runbooks/G4_PHASE5_STORE_MANAGER_POS_ACCESS_FIX.md` | Forward fix Store Manager pada Store assignment, cross-Store negative test, regression, dan PWA smoke |
| G4 fase 5 PWA tablet/Pricelist/receipt | `runbooks/G4_PHASE5_PWA_TABLET_PRICELIST_RECEIPT.md` | Tablet-first checkout, Customer Pricelist AUTO/override server-side, reset setelah POSTED, receipt tab cetak, rollout, dan smoke |
| G4 fase 6 Sale Draft list/edit-lock preflight | `runbooks/G4_PHASE6_SALE_DRAFT_EDIT_LOCK_PREFLIGHT.md` | SELECT-only audit side-effect-free Draft, cross-session Store scope, stale age, lifecycle metadata, single-editor heartbeat lock, takeover/force release, cancel, audit, RPC, dan direct-write boundary |
| G4 fase 6 Sale Draft list/edit-lock rollout | `runbooks/G4_PHASE6_SALE_DRAFT_EDIT_LOCK_ROLLOUT.md` | Nomor/metadata Draft, same-Store visibility, five-minute heartbeat lock, confirmed takeover, Manager/Admin force release, cancel, audit, guarded Save/Post, postflight, dan behavior |
| G4 fase 7 Sale Draft PWA UI | `runbooks/G4_PHASE7_SALE_DRAFT_PWA_UI.md` | Daftar Draft user-facing, resume dengan repricing, payment reconfirm, heartbeat, takeover, force release, cancel, Escape, dan authenticated tablet smoke |
| G4 fase 8 Split Payment preflight | `runbooks/G4_PHASE8_SPLIT_PAYMENT_PREFLIGHT.md` | Audit SELECT-only multi-leg server loop, per-leg fee, Store method readiness, posted totals/snapshots, tender/change, payment-leg identity, dan direct-write boundary |
| G4 fase 8 Payment-Leg identity rollout | `runbooks/G4_PHASE8_PAYMENT_LEG_IDENTITY_ROLLOUT.md` | Stable client key per leg, server normalization, duplicate key/metode guard, persisted unique identity, receipt traceability, postflight, behavior, dan regression |
| G4 fase 9 Split Payment PWA UI | `runbooks/G4_PHASE9_SPLIT_PAYMENT_PWA_UI.md` | Multi-metode tablet UI, exact base-total validation, per-leg Cash/proof/fee estimate, stable retry key, receipt, compatibility, dan authenticated smoke |
| G4 fase 10 Online Checkout stress preflight | `runbooks/G4_PHASE10_ONLINE_CHECKOUT_STRESS_PREFLIGHT.md` | SELECT-only audit lock/idempotency identity, posted Sale effect, Payment/Movement/FIFO reconciliation, nonnegative stock, dan fixture dua Kasir sebelum true concurrency |
| G4 fase 10 true-concurrent Post stress | `runbooks/G4_PHASE10_TRUE_CONCURRENT_POST_STRESS.md` | Staging-only 20 request Post bersamaan dengan satu idempotency key, single final effect, dan verifikasi Movement/Payment/Event/audit |
| G4 fase 11 Offline Stock Allowance preflight | `runbooks/G4_PHASE11_OFFLINE_STOCK_ALLOWANCE_PREFLIGHT.md` | SELECT-only audit entitlement, Terminal/Session/Gudang, Payment offline, Stock–Movement–FIFO, identity, schema reservation/submission, dan browser write boundary sebelum mode offline dibuka |
| G4 fase 11 Offline Stock Allowance rollout | `runbooks/G4_PHASE11_OFFLINE_STOCK_ALLOWANCE_FOUNDATION_ROLLOUT.md` | Default Company/override Store/eligibility Terminal, reservation Session–Product Base UOM, stock/session guard, release/revoke audit, dan server-only submission envelope tanpa membuka sync/PWA offline |
| G4 fase 12 Offline submission/sync preflight | `runbooks/G4_PHASE12_OFFLINE_SYNC_PREFLIGHT.md` | SELECT-only audit submission/hash/version, allowance consumption, Sale/Payment snapshot, acknowledgement, payment exception/Finance, atomic sync routine, stock reconciliation, dan direct-write boundary |
| G4 fase 12 Offline Sale Sync rollout | `runbooks/G4_PHASE12_OFFLINE_SYNC_ROLLOUT.md` | Guarded hash/version submit, canonical Draft/Post, atomic allowance consumption, harga snapshot + variance audit, Payment verification exception, acknowledgement, postflight, behavior, dan rollback boundary tanpa membuka PWA offline |
| G4 fase 13 Offline PWA queue foundation | `runbooks/G4_PHASE13_OFFLINE_PWA_QUEUE_FOUNDATION.md` | Dexie v3 retained queue, canonical JSONB hash, stable submit/process/status retry, acknowledgement retention, dan explicit no-checkout/no-entitlement boundary |
| G4 fase 14 Offline catalog cache preflight | `runbooks/G4_PHASE14_OFFLINE_CATALOG_CACHE_PREFLIGHT.md` | SELECT-only audit authoritative snapshot RPC, Product-UOM, Pricelist, Tax, Payment, Terminal policy, allowance, submission, dan browser boundary sebelum cache Keranjang dibuka |
| G4 fase 14 Offline catalog snapshot rollout | `runbooks/G4_PHASE14_OFFLINE_CATALOG_SNAPSHOT_ROLLOUT.md` | Guarded open-Session/eligible-Terminal snapshot Product-UOM, Pricelist rules, Sales Tax, Payment, dan allowance tanpa mengaktifkan entitlement atau checkout Offline |
| G4 fase 15 retained Offline catalog cache | `runbooks/G4_PHASE15_OFFLINE_PWA_CATALOG_CACHE_FOUNDATION.md` | Dexie retained snapshot, exact scope/hash/freshness/invalidation, dan queue-aware allowance tanpa membuka checkout |
| G4 fase 16 read-only Offline status/cache UI | `runbooks/G4_PHASE16_OFFLINE_STATUS_CACHE_PWA_UI.md` | Status koneksi/scope/snapshot age/allowance di PWA; checkout tetap tertutup |
| G4 fase 17 Offline policy Backoffice UI | `runbooks/G4_PHASE17_OFFLINE_POLICY_BACKOFFICE_UI.md` | Guarded default Company, override Toko, dan eligibility Terminal dengan role/scope enforcement; entitlement tetap Super Admin-only |
| G4 fase 18 POS Customer quick-create | `runbooks/G4_PHASE18_POS_CUSTOMER_QUICK_CREATE_ROLLOUT.md` | Create-only Customer dari checkout, active-Company server scope, open-Session guard, automatic code, audit, dan selector Company adaptif |
| G4 fase 19 Offline Allowance operations UI | `runbooks/G4_PHASE19_OFFLINE_ALLOWANCE_OPERATIONS_UI.md` | Daftar Session–Product allowance, guarded issue/release/force-revoke, role scope, custom confirmation, dan explicit no-checkout boundary |
| G4 fase 20 Cashier Offline Allowance PWA UI | `runbooks/G4_PHASE20_CASHIER_OFFLINE_ALLOWANCE_PWA_UI.md` | Cashier meminta/melepas allowance sesi sendiri, melihat queue-adjusted quantity, dan merekonsiliasi cache tanpa membuka checkout Offline |
| G4 fase 21 Offline checkout queue preflight | `runbooks/G4_PHASE21_OFFLINE_CHECKOUT_QUEUE_PREFLIGHT.md` | SELECT-only audit RPC/grant, UAT scope, allowance, Product/Payment, submission identity/final effect, dan Stock–Movement–FIFO sebelum Keranjang Offline dibuka |
| G4 fase 22 Offline checkout queue PWA UI | `runbooks/G4_PHASE22_OFFLINE_CHECKOUT_QUEUE_PWA_UI.md` | Keranjang ke retained queue secara fail-closed, snapshot pricing, allowance/payment validation, Slip Offline, retry/status, dan invoice acknowledgement |
| G4 fase 22 POS end-to-end UAT | `runbooks/G4_PHASE22_POS_END_TO_END_UAT.md` | Checklist Online checkout, Draft, Split Payment, warm-session Offline queue/sync, negative path, idempotent retry, rekonsiliasi, dan evidence sebelum cold-start gate |
| G4 fase 23 Offline cold-start/conflict preflight | `runbooks/G4_PHASE23_OFFLINE_COLD_START_CONFLICT_PREFLIGHT.md` | SELECT-only audit identity, idempotency, lifecycle, status-first recovery, final-effect coverage, dan Stock–Movement–FIFO sebelum retained cold-start PWA dibuka |
| G4 fase 23 Offline cold-start/recovery PWA | `runbooks/G4_PHASE23_OFFLINE_COLD_START_RECOVERY_PWA.md` | Dexie v5 exact operational scope, cached-auth match, snapshot/catalog/queue restore, status-first reconnect, dan controlled retry tanpa membuka deferred module |
| G4 fase 24 Offline disconnect/reconnect stress | `runbooks/G4_PHASE24_OFFLINE_DISCONNECT_RECONNECT_STRESS.md` | SELECT-only baseline dan controlled network interruption pada submit/process/status dengan identity, final-effect, allowance, dan stock reconciliation |
| G4 fase 25 Sales Return readiness | `runbooks/G4_PHASE25_SALES_RETURN_READINESS_PREFLIGHT.md` | SELECT-only audit source Sale/line/Payment/receipt, Bundle/FIFO, Offline terminal state, refund/warehouse/Finance catalog, dan browser boundary sebelum Return dibuka |
| G4 fase 26 Sales Return foundation | `runbooks/G4_PHASE26_SALES_RETURN_FOUNDATION_ROLLOUT.md` | Guarded Draft/Post/Cancel, cumulative quantity, refund snapshot, FIFO restoration by condition, Cash Session integration, audit, idempotency, dan Finance HOLD; UI belum dibuka |
| G4 fase 27 Sales Return PWA Draft UI | `runbooks/G4_PHASE27_SALES_RETURN_PWA_DRAFT_UI.md` | Online invoice search, qty/kondisi, refund Cash/Transfer otomatis, dan Draft-only approval boundary untuk tablet smoke |
| G4 fase 28 Sales Return Backoffice approval UI | `runbooks/G4_PHASE28_SALES_RETURN_BACKOFFICE_APPROVAL_UI.md` | Review detail user-facing, guarded post/cancel REQUIRED approval, custom confirmation, dan role/store boundary smoke |
| G4 fase 29 Expense dan Cash Flow preflight | `runbooks/G4_PHASE29_EXPENSE_CASH_FLOW_PREFLIGHT.md` | SELECT-only audit Cash Advance legacy, Session/drawer, Cash/Transfer, kategori/akun, entitlement, privilege, dan gap canonical Expense |
| G4 fase 30 Expense request/approval foundation | `runbooks/G4_PHASE30_EXPENSE_REQUEST_APPROVAL_FOUNDATION_ROLLOUT.md` | Sembilan tabel canonical, default policy/category, guarded Draft/Submit/Review/Cancel, audit/RLS, dan cash-neutral boundary |
| G4 fase 31 Expense request PWA UI | `runbooks/G4_PHASE31_EXPENSE_REQUEST_PWA_UI.md` | Pengajuan online Cashier; disbursement/settlement/Cash In tetap tertutup |
| G4 fase 32 Expense approval Backoffice UI | `runbooks/G4_PHASE32_EXPENSE_APPROVAL_BACKOFFICE_UI.md` | Review/approve/reject/cancel cash-neutral pada modul Finance |
| G4 fase 33 Expense disbursement preflight | `runbooks/G4_PHASE33_EXPENSE_DISBURSEMENT_PREFLIGHT.md` | SELECT-only audit Expense approved, Cashier Session/drawer, metode Cash/Transfer, account/category, event snapshot, idempotency, dan reconciliation sebelum pencairan dibuka |
| G4 fase 34 Expense disbursement foundation | `runbooks/G4_PHASE34_EXPENSE_DISBURSEMENT_FOUNDATION_ROLLOUT.md` | Approved-only initial Cash/non-Cash disbursement, immutable approval/payment/account snapshot, drawer OUT, expected-cash integration, idempotency, audit, dan Finance HOLD |
| G4 fase 35 Expense disbursement UI | `runbooks/G4_PHASE35_EXPENSE_DISBURSEMENT_UI.md` | Cash melalui active POS Session dan non-Cash melalui Finance Backoffice; nominal/metode server-authoritative, settlement/return/Cash In tetap tertutup |
| G4 fase 36 Expense settlement preflight | `runbooks/G4_PHASE36_EXPENSE_SETTLEMENT_PREFLIGHT.md` | SELECT-only audit actual Expense, return, outstanding, additional disbursement, Cash In readiness, event totals, dan gap runtime sebelum settlement dibuka |
| G4 fase 37 Expense settlement foundation | `runbooks/G4_PHASE37_EXPENSE_SETTLEMENT_FOUNDATION_ROLLOUT.md` | Reviewed actual, immutable settlement/return, Cash In drawer reconciliation, outstanding lifecycle, dan request-only additional disbursement |
| G4 fase 38 Expense settlement operational UI | `runbooks/G4_PHASE38_EXPENSE_SETTLEMENT_OPERATIONAL_UI.md` | POS actual/return Cash/request tambahan dan Backoffice review actual/return non-Cash tanpa membuka execution tambahan atau jurnal final |
| G4 fase 39 Additional Expense disbursement preflight | `runbooks/G4_PHASE39_ADDITIONAL_EXPENSE_DISBURSEMENT_PREFLIGHT.md` | SELECT-only audit lifecycle request tambahan, approval/execution gap, zero cash effect, payment/session readiness, tenant integrity, dan direct-write boundary |
| G4 fase 40 Additional Expense disbursement rollout | `runbooks/G4_PHASE40_ADDITIONAL_EXPENSE_DISBURSEMENT_ROLLOUT.md` | Guarded review/reject dan Cash/non-Cash execution, exact idempotency, drawer isolation, audit, serta Finance HOLD tanpa membuka Deposit/G6 |
| G4 fase 41 Additional Expense operational UI | `runbooks/G4_PHASE41_ADDITIONAL_EXPENSE_OPERATIONAL_UI.md` | Backoffice review/non-Cash execution dan POS Cash execution melalui Session aktif, tanpa membuka Deposit/Offline Expense/G6 |
| G4 fase 42 Cash Deposit preflight | `runbooks/G4_PHASE42_CASH_DEPOSIT_PREFLIGHT.md` | SELECT-only audit Setor Kas multi-sesi, legacy bank deposit, closed Session, account/category, variance schema, trigger, dan direct-write boundary |
| G4 fase 43 Cash Deposit foundation | `runbooks/G4_PHASE43_CASH_DEPOSIT_FOUNDATION_ROLLOUT.md` | Guarded multi-sesi Draft/Submit/Approve/Reject/Cancel, Session lock, proof policy, variance exception, immutable audit, dan Financial Event HOLD tanpa membuka UI/G6 |
| G4 fase 44 Cash Deposit operational UI | `runbooks/G4_PHASE44_CASH_DEPOSIT_OPERATIONAL_UI.md` | PWA create/submit dari Session CLOSED dan Backoffice Finance approve/reject dengan detail per sesi; bank matching, variance resolution, Offline Deposit, dan G6 tetap tertutup |
| G4 fase 45 Deposit variance resolution preflight | `runbooks/G4_PHASE45_DEPOSIT_VARIANCE_RESOLUTION_PREFLIGHT.md` | Audit SELECT-only exception coverage, lifecycle, responsible party, allocation reconciliation, account readiness, maker-checker/runtime gap, dan direct-write boundary |
| G4 fase 46 Deposit variance resolution rollout | `runbooks/G4_PHASE46_DEPOSIT_VARIANCE_RESOLUTION_ROLLOUT.md` | Responsible-party audit, partial append-only resolution, maker-checker loss/income, exact idempotency, dan Financial Event HOLD tanpa bank matching/G6 |
| G4 fase 47 Deposit variance operational UI | `runbooks/G4_PHASE47_DEPOSIT_VARIANCE_OPERATIONAL_UI.md` | Backoffice tenant-scoped list/detail, responsible party, partial resolution, maker-checker role UI, Escape, dan authenticated smoke tanpa bank matching/reversal/G6 |
| G4 fase 48 Customer Balance preflight | `runbooks/G4_PHASE48_CUSTOMER_BALANCE_PREFLIGHT.md` | SELECT-only audit entitlement, legacy balance/payment, internal method, category/account, closed Sale runtime, privilege, serta canonical ledger/RPC gap sebelum POS-006 dibuka |
| G4 fase 49 Customer Balance foundation | `runbooks/G4_PHASE49_CUSTOMER_BALANCE_FOUNDATION_ROLLOUT.md` | Company lifecycle ACTIVE/WIND_DOWN/DISABLED, system internal method, append-only ledger, guarded maker-checker correction, statement, audit/idempotency, dan Finance HOLD tanpa checkout/refund/offline/G6 |
| G4 fase 49 Customer Balance digest fix | `runbooks/G4_PHASE49_CUSTOMER_BALANCE_FOUNDATION_ROLLOUT.md` | Forward fix schema-qualified `extensions.digest(bytea,text)` untuk request hash; migration foundation tidak direrun |
| G4 fase 50 Customer Balance operational UI | `runbooks/G4_PHASE50_CUSTOMER_BALANCE_OPERATIONAL_UI.md` | Backoffice liability, correction request/review maker-checker, dan statement user-facing melalui RPC guarded; checkout/refund/offline/G6 tetap tertutup |
| G4 fase 51 Customer Balance Sale credit preflight | `runbooks/G4_PHASE51_CUSTOMER_BALANCE_SALE_CREDIT_PREFLIGHT.md` | SELECT-only audit kelebihan Transfer/kembalian Cash, Payment snapshot, ledger source, account/category, identity, dan atomic Sale runtime sebelum credit saldo dibuka |
| G4 fase 52 Customer Balance Sale credit rollout | `runbooks/G4_PHASE52_CUSTOMER_BALANCE_SALE_CREDIT_ROLLOUT.md` | Atomic ONLINE Sale overpayment credit, append-only ledger/cache, Payment/receipt snapshot, idempotency, compatibility kembalian Cash, postflight/behavior/regression |
| G4 fase 53 POS overpayment disposition UI | `runbooks/G4_PHASE53_POS_OVERPAYMENT_DISPOSITION_UI.md` | Pilihan kembalikan atau simpan saldo untuk selisih Cash/Transfer online, regular-Customer eligibility, receipt snapshot, dan Offline fail-closed |
| G4 fase 54 Customer Balance tender preflight | `runbooks/G4_PHASE54_CUSTOMER_BALANCE_TENDER_PREFLIGHT.md` | SELECT-only audit mandatory full-balance usage, lifecycle ACTIVE/WIND_DOWN, ledger/cache, account/category, Payment snapshot, runtime defer guard, dan browser write boundary |
| G4 fase 55 POS negative-stock permission preflight | `runbooks/G4_PHASE55_POS_NEGATIVE_STOCK_PERMISSION_PREFLIGHT.md` | SELECT-only audit optional online permission, Warehouse hard guard, shortage runtime, Stock–Movement–FIFO, provisional cost/replenishment gap, Offline fail-closed, dan direct-write boundary |
| G4 fase 56 Customer Balance tender rollout | `runbooks/G4_PHASE56_CUSTOMER_BALANCE_TENDER_ROLLOUT.md` | Mandatory full-balance ONLINE tender, Payment/receipt snapshot, append-only debit/cache/Event/audit, exact retry, dan WIND_DOWN closure |
| G4 fase 57 Customer Balance tender UI | `runbooks/G4_PHASE57_CUSTOMER_BALANCE_TENDER_UI.md` | Saldo Customer user-facing, automatic full-balance leg, minimum tambah belanja, receipt/print, dan Offline fail-closed |
| G4 fase 58 POS Negative Stock policy foundation | `runbooks/G4_PHASE58_NEGATIVE_STOCK_POLICY_FOUNDATION_ROLLOUT.md` | Default-OFF entitlement/policy, opt-in Gudang, permission user, audit, serta schema authorization/replenishment tanpa membuka shortage bypass |
| G4 fase 59 POS Negative Stock runtime preflight | `runbooks/G4_PHASE59_NEGATIVE_STOCK_RUNTIME_PREFLIGHT.md` | SELECT-only audit config chain, provisional HPP, Movement guard, online Sale allocation, Offline boundary, dan replenishment dependency |
| G4 fase 60 POS Negative Stock online runtime | `runbooks/G4_PHASE60_NEGATIVE_STOCK_ONLINE_RUNTIME_ROLLOUT.md` | Atomic authorization, provisional HPP, controlled negative Movement, outstanding allocation, dan automatic incoming-batch reconciliation; default OFF |
| G4 fase 61 POS Negative Stock operational UI | `runbooks/G4_PHASE61_NEGATIVE_STOCK_OPERATIONAL_UI.md` | Guarded Backoffice policy/Gudang/user permission dan server-triggered POS reason/retry; online non-Bundle saja |
| G5 fase 1 Purchasing foundation preflight | `runbooks/G5_PHASE1_PURCHASING_FOUNDATION_PREFLIGHT.md` | SELECT-only audit legacy Purchase, Request/Order gap, master/tenant/security, Goods Receipt category, dan replenishment dependency |
| G5 fase 2 Stock Request + Supplier Order rollout | `runbooks/G5_PHASE2_STOCK_REQUEST_SUPPLIER_ORDER_ROLLOUT.md` | Guarded Request Kasir dan Order Store Manager/Admin, allocation/version/idempotency/audit, tanpa efek Stock/FIFO/AP/Finance |
| G5 fase 4 Goods Receipt preflight | `runbooks/G5_PHASE4_GOODS_RECEIPT_PREFLIGHT.md` | SELECT-only audit Order source, Gudang/kondisi, Stock/FIFO/Movement, AP provisional, Finance HOLD, dan browser boundary |
| G5 fase 5 Goods Receipt rollout | `runbooks/G5_PHASE5_GOODS_RECEIPT_FOUNDATION_ROLLOUT.md` | Guarded Draft/Post/Cancel, partial/over, kondisi baik/rusak/ditolak, Stock/FIFO/Movement, AP provisional, Event HOLD, audit, dan forward fix history trigger |
| G5 fase 6 Goods Receipt PWA smoke | `runbooks/G5_PHASE6_GOODS_RECEIPT_PWA_SMOKE.md` | Order Store aktif, Draft/resume/cancel, partial/over, kondisi barang, Post atomic; authenticated receive diterima user |
| G5 fase 7 Purchase Return preflight | `runbooks/G5_PHASE7_PURCHASE_RETURN_PREFLIGHT.md` | SELECT-only audit source receipt, returnable FIFO, Purchase Movement, AP provisional, category/event, reconciliation, schema/RPC, dan browser boundary |
| G5 fase 8 Purchase Return rollout | `runbooks/G5_PHASE8_PURCHASE_RETURN_FOUNDATION_ROLLOUT.md` | Cashier Draft, manager review/Post, exact source FIFO consumption, Stock Movement, append-only AP adjustment, Finance HOLD, idempotency, audit, dan browser write closure |
| G5 fase 9 Purchase Return operational UI | `runbooks/G5_PHASE9_PURCHASE_RETURN_OPERATIONAL_UI.md` | POS Draft dari Receipt/FIFO asal; Backoffice review terpisah dari Post; authenticated end-to-end smoke checklist |
| G5 fase 10 Supplier Invoice preflight | `runbooks/G5_PHASE10_SUPPLIER_INVOICE_PREFLIGHT.md` | Audit legacy Purchase, AP provisional net of Return, matching scope, Finance catalog, Tax Purchase, schema, dan browser boundary |
| G5 fase 11 Supplier Invoice matching rollout | `runbooks/G5_PHASE11_SUPPLIER_INVOICE_MATCHING_FOUNDATION_ROLLOUT.md` | Guarded Draft/HOLD/VALIDATED, exact Receipt/AP allocation, tolerance dan Purchase Tax snapshot, residual reconciliation, last purchase price, audit, serta Finance HOLD tanpa Stock effect |
| G5 optional tolerance corrective forward fix | `runbooks/G5_OPTIONAL_TOLERANCE_CONTRACT_FORWARD_FIX.md` | Memformalkan keputusan optional policy secara forward-only; tanpa policy value variance fleksibel tetapi quantity Receipt dan variance snapshot tetap wajib |
| G6 corrective posting preflight | `runbooks/G6_PHASE1_POSTING_ENGINE_PREFLIGHT.md` | SELECT-only audit live-state, rejected draft ledger, tenant/RPC boundary, canonical rule guard, event-journal integrity, dan Finance master readiness sebelum posting dibuka |
| G6 corrective phase 5 queue preflight | `runbooks/G6_PHASE5_CONTROLLED_QUEUE_PREFLIGHT.md` | SELECT-only audit supported historical HOLD, source/rule/period, active-Company scope, exception inventory, expected preview/approval/processor, dan browser boundary |
| G6 corrective phase 5 queue rollout | `runbooks/G6_PHASE5_CONTROLLED_POSTING_QUEUE_ROLLOUT.md` | Single active-Company preview/approval/process queue, immutable snapshot/audit, per-event failure isolation, Phase-4 authority, dan zero automatic HOLD processing |
| G6 corrective phase 6 report/reconciliation preflight | `runbooks/G6_PHASE6_REPORTING_RECONCILIATION_PREFLIGHT.md` | SELECT-only POSTED ledger, timezone/cut-off, report object, pending analysis, serta Stock/AP/Customer Balance versus GL audit |
| G6 corrective phase 6A POSTED reports rollout | `runbooks/G6_PHASE6A_POSTED_FINANCIAL_REPORTS_ROLLOUT.md` | Trial Balance dan General Ledger tenant/role/timezone-aware dari canonical journal POSTED; tanpa memproses HOLD atau membuat adjustment |
| G6 corrective phase 6B live reconciliation preflight | `runbooks/G6_PHASE6B_STOCK_OPENING_LIVE_RECONCILIATION_PREFLIGHT.md` | SELECT-only gate source/rule/period/queue/report dan FIFO–Inventory GL sebelum satu STOCK_OPENING live diproses terkontrol |
| G6 corrective phase 6B controlled live posting | `runbooks/G6_PHASE6B_CONTROLLED_LIVE_STOCK_OPENING.md` | Maintenance operation satu reviewed STOCK_OPENING Rp450.000, exact queue scope, audit, dan closing event/journal/report/FIFO–GL verification |
| G6 corrective phase 6C statements preflight | `runbooks/G6_PHASE6C_STATEMENTS_PENDING_RECONCILIATION_PREFLIGHT.md` | SELECT-only P&L, Neraca equation, pending HOLD analysis, reconciliation read model, report fixture, privilege, dan FIFO–GL deferred exposure |
| G6 corrective phase 6C statements rollout | `runbooks/G6_PHASE6C_STATEMENTS_PENDING_RECONCILIATION_ROLLOUT.md` | POSTED-only P&L/Neraca, explicitly separated pending exposure, current-only reconciliation summary, versioned metadata, immutable foundation, dan no-adjustment boundary |
| G6 corrective phase 7 operations/pilot preflight | `runbooks/G6_PHASE7_FINANCE_OPERATIONS_PILOT_PREFLIGHT.md` | SELECT-only gate canonical posting queue, append-only reversal gap, period lifecycle, pilot roles, tenant/browser boundary, reports, dan deferred FIFO–GL/HOLD exposure |
| G6 corrective phase 7A append-only reversal rollout | `runbooks/G6_PHASE7A_APPEND_ONLY_JOURNAL_REVERSAL_ROLLOUT.md` | Guarded reversal jurnal Manual/Opening Balance pada period terbuka, exact idempotency, immutable source snapshot, audit, tenant/role boundary, dan source-controlled operational correction |
| G6 corrective phase 7B Finance Operations UI | `runbooks/G6_PHASE7B_FINANCE_OPERATIONS_UI.md` | Role-aware canonical jurnal, append-only reversal, accounting period, controlled STOCK_OPENING queue, POSTED reports, pending analysis, dan current-only reconciliation smoke |
| G6 corrective phase 7B human IDs, Ledger, dan Excel | `runbooks/G6_PHASE7B_FINANCE_HUMAN_IDS_LEDGER_EXPORT.md` | Manual rollout `JUR/JRB/PST/EXC/REC`, Buku Besar account-centric expandable, Journal Entries document-centric, monthly XLSX, compatibility, dan tenant smoke |
| G4 fase 15 Offline PWA catalog cache | `runbooks/G4_PHASE15_OFFLINE_PWA_CATALOG_CACHE_FOUNDATION.md` | Dexie v4 retained snapshot, exact scope/hash/freshness/invalidation, dan local allowance reconciliation tanpa membuka checkout Offline |
| G4 fase 16 Offline status/cache PWA UI | `runbooks/G4_PHASE16_OFFLINE_STATUS_CACHE_PWA_UI.md` | Read-only connection/snapshot/scope/age/allowance panel, lazy cache chunk, explicit blocked-checkout state, dan authenticated smoke tertutup |
| Kontrak CSV fixed Master Import | `MASTER_IMPORT_FIXED_CSV_CONTRACTS.md` | Header versioned, dependency order, atomic group, referensi nama/kode, validation limit, serta master yang wajib memakai workflow khusus |
| Global Role-Aware Data Exchange Center | `GLOBAL_DATA_EXCHANGE_CENTER_SPEC.md` | Requirement pre-deploy untuk catalog module/type/action server-authoritative, Finance XLSX, guarded import, dan cutover entry point Inventory |
| Pre-deploy modular Home, branding, dan Sales document | `PREDEPLOY_MODULAR_HOME_BRANDING_SALES_DOCUMENT_PLAN.md` | Two-level authorized launcher, logo Company, Sales Invoice printable, Surat Jalan delivery-only, phase, invariant, dan regression sebelum Vercel Preview |
| Company branding/logo specification | `COMPANY_BRANDING_LOGO_SPEC.md` | Tenant ownership, MIME/size/checksum, public-read/server-write Storage, version/cache, audit, snapshot, dan negative tests |
| UXD-1 navigation authority dan repository hygiene audit | `audits/UXD1_NAVIGATION_AUTHORITY_AND_REPOSITORY_HYGIENE_AUDIT_2026-08-11.md` | Role/module ownership, API boundary, UXD-2 server catalog contract, ukuran repository, secret/artifact scan, dan kebijakan canonical SQL tetap tracked |
| UXD-2 two-level launcher rollout | `runbooks/UXD2_TWO_LEVEL_LAUNCHER_ROLLOUT.md` | Server-readable role/feature catalog, clean Home, module landing, Company reset, build evidence, dan authenticated matrix smoke |
| BRD-1 Company branding preflight | `runbooks/BRD1_COMPANY_BRANDING_PREFLIGHT.md` | SELECT-only Company/role/Storage/bucket/policy/schema readiness sebelum migration logo |
| BRD-1 Company branding foundation rollout | `runbooks/BRD1_COMPANY_BRANDING_FOUNDATION_ROLLOUT.md` | Migration, postflight, guarded branding RPC/bucket, audit/version, dan rollback-safe two-Company isolation behavior |
| BRD-2 Company branding upload dan UI | `runbooks/BRD2_COMPANY_BRANDING_UPLOAD_UI.md` | Server-only upload, magic-byte/checksum/path validation, replace/remove cleanup, Company setting, dan authenticated multi-Company smoke |
| Sales Invoice dan Surat Jalan canonical | `SALES_INVOICE_DELIVERY_DOCUMENT_SPEC.md` | Single-source Sale POSTED, immutable print snapshot, delivery-only document, human number, lifecycle, idempotency, offline/Return/Bundle, tenant dan no-double-effect contract |
| Revisi checkout Delivery dan ongkir | `SLD_DELIVERY_FEE_REVISION_PLAN.md` | Checkbox final checkout, Customer autofill, ongkir server-authoritative, Invoice display mode, Finance mapping, offline/Return, dan urutan SLD-R1—R4 |
| SLD-1 Sales document preflight | `runbooks/SLD1_SALES_DOCUMENT_PREFLIGHT.md` | SELECT-only audit Sale/line/payment/receipt/Return/Offline/Bundle/branding dan interpretasi blocker sebelum SLD-2 |
| SLD-2 Sales document foundation rollout | `runbooks/SLD2_SALES_DOCUMENT_FOUNDATION_ROLLOUT.md` | Immutable Invoice snapshot, delivery-only Surat Jalan, legacy cutover, deferred finalization, tenant/audit/logo retention, postflight dan regression tanpa double Stock/Finance effect |
| SLD-3 POS/Backoffice printable document UAT | `runbooks/SLD3_POS_BACKOFFICE_PRINT_UI.md` | Pickup/Delivery checkout, Invoice/SJ A4 new-tab print, Backoffice lifecycle, role, tenant, offline, dan no-double-effect smoke |
| Inventory Surat Jalan authority split | `runbooks/INVENTORY_DELIVERY_DOCUMENT_AUTHORITY_ROLLOUT.md` | Pisahkan Sales Invoice dan Inventory Surat Jalan tanpa mengubah canonical Sale/POS/history |
| SLD-R1 Delivery fee preflight | `runbooks/SLD_R1_DELIVERY_FEE_PREFLIGHT.md` | SELECT-only audit Sale/payment/offline/Return/Invoice/Finance readiness sebelum canonical ongkir R2 |
| SLD-R2 Delivery fee foundation rollout | `runbooks/SLD_R2_DELIVERY_FEE_FOUNDATION_ROLLOUT.md` | Additive fee schema, retry-safe Draft total, Payment/Invoice/Event reconciliation, Company revenue mapping, postflight, behavior, compatibility, dan controlled G6 deferral |
| SLD-R3 Delivery checkout/print UAT | `runbooks/SLD_R3_DELIVERY_CHECKOUT_PRINT_UAT.md` | Authenticated online/offline smoke untuk checkbox final, Customer autofill, ongkir, payment, Invoice display mode, Surat Jalan, Draft restore, dan tenant boundary |
| SLD-R4 Delivery fee Return preflight | `runbooks/SLD_R4_DELIVERY_FEE_RETURN_PREFLIGHT.md` | SELECT-only audit untuk explicit full-return fee refund, partial-return guard, Draft normalization, payment/event reconciliation, role, Offline, dan G6 boundary |
| PRD-1 pre-deploy closing preflight | `runbooks/PRD1_PREDEPLOY_CLOSING_PREFLIGHT.md` | SELECT-only gate migration chain, dua Company, role UAT, Stock/FIFO, Finance, Invoice/SJ/Return, tenant boundary, dan kesiapan sebelum Vercel Preview |
| PRD-1 UAT identity dan tenant setup | `runbooks/PRD1_UAT_IDENTITY_TENANT_SETUP.md` | Manual canonical Company/role/Cashier/multi-Company fixture serta SELECT-only tenant readiness postflight tanpa menyimpan kredensial |
| PRD-1 existing-user multi-Company rollout | `runbooks/PRD1_EXISTING_USER_MULTI_COMPANY_ROLLOUT.md` | Super-Admin-only assignment akun existing ke Company aktif, role per Company, optional Store, exact retry, immutable audit, dan selector Company tanpa global directory browser |
| DEX-1 access/catalog audit | `audits/DEX1_GLOBAL_DATA_EXCHANGE_ACCESS_CATALOG_AUDIT_2026-08-11.md` | Peta execution path aktif, katalog existing, gap permission/action, Finance export, dan target contract DEX-2 tanpa runtime cutover |
| DEX-2 role-aware Export Center | `runbooks/DEX2_ROLE_AWARE_EXPORT_CENTER.md` | Server-owned catalog/action guard, global export UI, tujuh Finance XLSX, compatibility, dan authenticated role/cross-Company smoke |
| DEX-3 global Import consolidation | `runbooks/DEX3_GLOBAL_IMPORT_CONSOLIDATION.md` | Global Import berbasis catalog server yang memakai ulang fixed template, staging, preview, guarded commit, history, compatibility, dan parity smoke |
| DEX-4 Inventory cutover | `runbooks/DEX4_INVENTORY_CUTOVER_AND_DEPLOYMENT_EVIDENCE.md` | Satu visible Global Data Exchange, retirement navigation Inventory lama, compatibility backend, regression, dan post-cutover deployment evidence |
| Panduan user Kategori Transaksi | `FINANCE_TRANSACTION_CATEGORY_USER_GUIDE.md` | Penjelasan sederhana seluruh kategori bawaan, kapan dipakai, contoh Expense khusus, dan arti mapping akun |
| G2 fase 8 Customer rollout | `runbooks/G2_PHASE8_CUSTOMER_FOUNDATION_ROLLOUT.md` | Customer Category/Customer schema, Walk-In provisioning, automatic code, guarded RPC, RLS, audit, postflight, dan behavioral test |
| Active development handoff | `ACTIVE_DEVELOPMENT_HANDOFF.md` | Catatan wajib antar-agent: status gate, evidence, manual action, next safe step, dan acuan Markdown per development |
| Prompt copas agent pengganti | `AGENT_CONTINUATION_COPY_PASTE_PROMPT.md` | Prompt stabil yang selalu memerintahkan agent membaca living handoff terbaru sebelum melanjutkan |
| Simulasi quota | `CAPACITY_SIMULATION_HANDOFF.md` | Route/schema aktif dan dashboard metrik saat pengukuran |
| Bukti pembayaran, foto, attachment | `EXTERNAL_EVIDENCE_LINK_POLICY.md` | Spesifikasi modul untuk status/approval dokumen |
| Pedoman development | `DEVELOPMENT_TRACEABILITY_AND_FREE_TIER_NOTES.md` | README modul target ketika sudah dibuat |
| Playbook wajib agent/handoff berulang | `AI_AGENT_CONTINUATION_PLAYBOOK.md` | Index requirement, gate aktif, gap audit, dan spesifikasi modul target |
| Arah POS menjadi ERP modular | `ERP_EVOLUTION_ARCHITECTURE_NOTES.md` | Pedoman development dan spesifikasi modul aktif |

## Precedence

1. keputusan user terbaru pada spesifikasi modul;
2. spesifikasi modul khusus;
3. review lintas modul;
4. auth/RLS architecture;
5. snapshot current-state/gap lama.

Untuk pekerjaan build POS v1, mulai dari `POS_V1_MVP_REQUIREMENT_INDEX.md`, lalu baca gap dan gate terkait sebelum membuka spesifikasi modul.

File `database-current-state.md` dan `multi-company-gap-analysis.md` adalah snapshot historis; jangan menggunakannya untuk mengalahkan keputusan business terbaru.

## Aturan untuk AI Agent

- Baca dan ikuti `AI_AGENT_CONTINUATION_PLAYBOOK.md` sebelum mengubah repository.
- Mulai dari baris tugas pada tabel di atas.
- Ikuti pointer dependency, jangan broad-read tanpa alasan.
- Bedakan `APPROVED`, open decision, design note, dan implemented evidence.
- Jangan mengubah schema/UI hanya karena requirement sudah disetujui.
- Periksa execution path aktif sebelum menyatakan fitur selesai.
- Setelah perubahan, perbarui source-of-truth dan decision log terkait saja; hindari menyalin keputusan ke banyak file kecuali diperlukan sebagai boundary lintas modul.
## Rollout terbaru

- [Stok Minus POS ke Permintaan Barang per Sesi](runbooks/PRD_NEGATIVE_STOCK_SESSION_REQUEST_ROLLOUT.md)
