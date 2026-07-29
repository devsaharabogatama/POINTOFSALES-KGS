# Router Dokumen KGS POS

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
| Modal dan Aset | `CAPITAL_AND_ASSET_NOTES.md` | Finance saat fase detail dibuka |
| Role, tenant, RLS | `../KGS_BACKOFFICE_AUTH_FLOW_WORKFLOW.md`, `rls-access-matrix.md` | Multi-company docs/migration yang relevan |
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
| Kontrak CSV fixed Master Import | `MASTER_IMPORT_FIXED_CSV_CONTRACTS.md` | Header versioned, dependency order, atomic group, referensi nama/kode, validation limit, serta master yang wajib memakai workflow khusus |
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
