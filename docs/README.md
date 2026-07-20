# Router Dokumen KGS POS

Gunakan file ini sebagai entrypoint. Jangan membaca seluruh folder `docs` untuk setiap tugas.

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
| G1 fase 2 PostgREST compatibility | `audits/G1_PHASE2_POSTGREST_COMPATIBILITY_2026-07-20.md` | Relationship hint Product → Stock → Warehouse |
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
