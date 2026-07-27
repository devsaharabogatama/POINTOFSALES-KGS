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
