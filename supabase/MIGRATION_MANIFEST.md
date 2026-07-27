# Supabase Migration Manifest — G0 Baseline

**Status:** G0 CLOSED; G1 CLOSED; canonical forward chain dimulai dari `20260720090000`
**Tanggal inventaris:** 2026-07-20  
**Aturan:** jangan menjalankan file legacy sebagai batch production. Semua perubahan baru wajib forward migration bernomor di `supabase/migrations/`.

---

## 1. Kesimpulan Inventaris

Repository belum memiliki satu migration chain yang dapat dianggap canonical:

- `schema.sql` adalah bootstrap legacy, bukan migration idempotent;
- hanya dua file berada di `migrations/`;
- migration `001` bergantung pada tabel dari `inventory_migration.sql`, tetapi dependency itu berada di luar folder migration;
- beberapa standalone RPC saling mengganti function yang sama;
- `policies.sql` mengulang helper/policy yang juga ada pada migration `002`;
- `fix_permissions.sql` memberi default privilege luas dan perlu diaudit bersama seluruh RLS/function grant;
- seed Company memakai ID/nama tetap dan tidak boleh dianggap production migration.

Karena itu G0 membekukan penambahan SQL ad-hoc baru. Setelah applied-state live diketahui, semua perubahan schema berikutnya wajib berupa migration bernomor baru di `supabase/migrations/`.

---

## 2. Klasifikasi File Existing

| File | SHA-256 snapshot | Klasifikasi | Dependency/overlap | Keputusan G0 |
|---|---|---|---|---|
| `schema.sql` | `01f5fc38e54f7fc8ccb881502ca243325e5afac1f3dc45723d28756f915d8e47` | LEGACY BOOTSTRAP | Membuat enum/table/index/RLS skeleton dari nol. Tidak idempotent untuk enum/table. | Jangan replay pada database existing. Dipakai sebagai evidence baseline lama. |
| `inventory_migration.sql` | `2ede32d23acaf9730514069caf16cd2bfd44470876cff60089cd6ed95109e7a4` | LEGACY ADDITIVE | Memerlukan `schema.sql`; membuat UOM/FIFO/opname/movement dan versi awal transfer RPC. | Jangan replay sebelum live diff; transfer function-nya disupersede. |
| `migrations/001_multi_company_setup.sql` | `958b62d036b12ec710bb6cc2eb5491e10763f8e6b57fb1502553957413ee645c` | APPLIED CANDIDATE | Memerlukan core table dan optional inventory table; melakukan seed/backfill ke UUID Company tetap. | Verifikasi migration registry dan object/data live. Jangan rerun. |
| `migrations/002_secure_tenant_product_weight_import.sql` | `401a579adb6059d310fa5f1f5fb14fc55c63d2495cbdb957402ee5ac700190ee` | APPLIED CANDIDATE | Memerlukan 001 + inventory; overlap helper/core policy dan grants. | Verifikasi live. Jangan rerun sampai checksum/applied-state cocok. |
| `customer_pricelist_migration.sql` | `f90a4d0dd0fdc435cd5e023ea60dc6edc13f2ef253a30eed21fcadf1389269dc` | LEGACY ADDITIVE | Memerlukan Company/Customer/Product/helper RLS; modelnya belum sesuai Pricelist v1 final. | Preserve data/object bila ada; jangan jadikan target schema G2. |
| `checkout_rpc.sql` | `e1a0594ef89fa3a18c7729154b8213f632b71731595face3923ef85c1f693e2a` | ACTIVE CANDIDATE / BLOCKED G4 | Memerlukan multi-company schema; client-value trust masih menjadi blocker. | Inventory signature/grant live; jangan dianggap final. |
| `transfer_rpc.sql` | `92168ad14afa38067dbadf2c5af572de7b50eb0f1152f9dc735a294f7d6a9e18` | SUPERSEDES LEGACY FUNCTION / BLOCKED G3 | Mengganti `transfer_product_stock` dari inventory migration; negative/concurrency issue. | Inventory live definition; jangan replay sebagai fix. |
| `confirm_purchase_rpc.sql` | `349ea880527ff68b855f4433b21f87cd539717a125370767a41863d1fedc06ef` | LEGACY ACTIVE CANDIDATE / BLOCKED G5 | Direct confirm model bertentangan dengan state machine purchase target. | Preserve compatibility; jangan kembangkan sebagai target flow. |
| `triggers.sql` | `e17fe5f7212521bece66a8c1828b22fa56e8c4e7577add03c108369be1ca7bd8` | LEGACY FINANCE SOURCE | Cash Advance/Bank Deposit model lama. | Inventory live; migrasi bertahap pada G4/G6. |
| `worker_rpc.sql` | `1612bbbbe3329be16d2c9f8ed648f6ff5bcdb51a74a102d7e2ba01f97c8c7ba4` | LEGACY FINANCE WORKER / BLOCKED G6 | COA hard-coded; bergantung event/journal lama. | Jangan patch account hard-coded; replace melalui mapping engine G6. |
| `policies.sql` | `1d053f4a9c111397a71d0ffbfeb442d9b869e6d7a28b4188e09196a81d0826fb` | POLICY BUNDLE / OVERLAP | Mengulang helper/core policy dari 001/002 dan menambah policy tabel lain. | Jadikan evidence; G1 akan menghasilkan migration policy canonical. |
| `fix_permissions.sql` | `83ef838671a003632be5a7253febf4f228c380f111b886cc8e12d15620933e66` | SECURITY BUNDLE / REVIEW REQUIRED | `GRANT EXECUTE ON ALL FUNCTIONS` dan default privileges luas bergantung RLS/revoke per function. | Jangan rerun sebelum G1 privilege matrix selesai. |
| `seed_company_data.sql` | `ed980a59a77d912209fa7fabbc9c7ae4ecc23d2d3c3378286c62ac724bc5a727` | SEED ONLY | Company/Store/Warehouse tetap; bukan schema. | Hanya environment test/dev yang eksplisit. |
| `tests/multi_company_tests.sql` | `28556d48d5475f244c95cddb6e48b33c12453b9516de8b838c3d4aa43b85aa3e` | LEGACY TEST | Tiga skenario, fixture auth langsung, rollback. | Pertahankan sebagai evidence; perlu diganti/diperluas per gate. |

Hash di atas mengidentifikasi snapshot lokal saat inventaris. Perubahan file setelah tanggal ini harus memperbarui manifest atau dicatat sebagai migration baru; jangan mengedit file yang sudah terbukti applied hanya agar hash cocok.

---

## 3. Dependency Reconstruction — Bukan Run Order Production

Urutan historis yang paling mungkin berdasarkan dependency file adalah:

```text
schema.sql
-> inventory_migration.sql
-> migrations/001_multi_company_setup.sql
-> migrations/002_secure_tenant_product_weight_import.sql
-> standalone customer/RPC/trigger/worker/policy/permission scripts
-> optional seed/test
```

Ini hanya reconstruction untuk audit. Tidak boleh dijalankan sebagai fresh-install automation karena:

- object creation tidak seluruhnya idempotent;
- fixed UUID seed/backfill dapat menempelkan data ke tenant yang salah;
- standalone script tidak memiliki applied ledger/checksum;
- urutan aktual di Supabase bisa berbeda;
- beberapa function/policy sudah diganti lebih dari sekali.

---

## 4. Aturan Canonical Mulai G0

1. Jangan membuat standalone SQL schema/RPC/policy baru di root `supabase/`.
2. Migration baru harus berada di `supabase/migrations/` dengan nama timestamp/urutan yang belum pernah applied.
3. Forward migration canonical pertama adalah `20260720090000_g1_phase1_security_feature_foundation.sql`.
4. File yang sudah applied tidak diedit; gunakan forward migration.
5. Setiap migration memuat:
   - requirement ID dan gate;
   - precondition;
   - perubahan additive/contract;
   - backfill dan ambiguous-row handling;
   - RLS/GRANT/function execute boundary;
   - verification query;
   - rollback atau forward-fix note.
6. Seed tidak digabung dengan schema migration kecuali reference seed yang tenant-neutral, versioned, dan idempotent.
7. Function `SECURITY DEFINER` wajib fixed `search_path`, actor/tenant validation, dan explicit revoke/grant.
8. Migration production tidak dijalankan sebelum staging restore test dan user menyetujui manual rollout.

---

## 5. Penutupan G0

- Baseline diagnostic sudah dijalankan pada 2026-07-20: 91 PASS, 15 WARN, 3 MISSING, 1 SKIP, 0 FAIL.
- Live tidak memiliki `supabase_migrations.schema_migrations`; applied-state harus direkonstruksi dari catalog fingerprint.
- `customer_pricelists` dan `confirm_purchase_order(...)` tidak ditemukan dan tidak boleh dipasang lewat legacy script.
- Delapan optional inventory table masih memiliki `company_id` nullable dengan nol row NULL saat baseline.
- Tujuh key function masih executable oleh `PUBLIC` dan memerlukan privilege review.
- Catalog fingerprint telah diterima: 1.100 row metadata mencakup column, constraint, index, policy, function, trigger, privilege, enum, dan extension.
- Effect utama migration 001/002 terbukti live, tetapi file exact yang pernah dijalankan tetap tidak dapat dibuktikan tanpa registry historis.
- G0 ditutup melalui `docs/audits/G0_LIVE_SCHEMA_BASELINE_2026-07-20.md`.
- Forward migration memakai ledger project `private.kgs_schema_migrations`; jangan menulis manual ke registry internal Supabase.
- Fresh-install/rebuild strategy tetap pekerjaan terpisah setelah production upgrade path G1 stabil.

## 6. Canonical Forward Chain

| Version | File | SHA-256 snapshot | Gate | Status | Dependency | Rollout |
|---|---|---|---|---|---|---|
| `20260720090000` | `migrations/20260720090000_g1_phase1_security_feature_foundation.sql` | `8487dda0383b0d96adb64a6c27e91d095817bc05da57268d2561627b7354dd3a` | G1 phase 1 | COMPLETE; DB + APP SMOKE PASS | G0 fingerprint 2026-07-20 | `docs/runbooks/G1_PHASE1_SECURITY_FEATURE_ROLLOUT.md` |
| `20260720120000` | `migrations/20260720120000_g1_phase2_core_tenant_consistency.sql` | `166c5a071cc78e62f8e708ab4f5c75e9847082e0e1a5e25613d2f110bf961cd5` | G1 phase 2 | COMPLETE; DB + LOCAL APP SMOKE PASS | G1 phase 1 complete | `docs/runbooks/G1_PHASE2_CORE_TENANT_ROLLOUT.md` |
| `20260720150000` | `migrations/20260720150000_g1_phase3_transaction_tenant_consistency.sql` | `3430e242a953cb3bbf26b654e3c2043ef25ca5ce40995488c6e08cc90dc2dbf4` | G1 phase 3 | COMPLETE; DB + LOCAL APP SMOKE PASS | G1 phase 2 complete | `docs/runbooks/G1_PHASE3_TRANSACTION_TENANT_ROLLOUT.md` |
| `20260720180000` | `migrations/20260720180000_g1_phase4_active_company_context.sql` | `cab73563c9b31f797d311747c1c456a4c8c5b19984abfcbe202349b1b57daf58` | G1 phase 4 | COMPLETE; DB + AUTHENTICATED APP INIT PASS | G1 phase 3 complete | `docs/runbooks/G1_PHASE4_ACTIVE_COMPANY_CONTEXT_ROLLOUT.md` |
| `20260720210000` | `migrations/20260720210000_g1_phase5a_core_role_rls.sql` | `a112981077ce67093a361e686d80fca7ea4aa33ddc5c764f1812f431fdeb6d4c` | G1 phase 5A | COMPLETE; DB TEST + LOCAL APP SMOKE PASS | G1 phase 4 complete | `docs/runbooks/G1_PHASE5A_CORE_ROLE_RLS_ROLLOUT.md` |
| `20260720230000` | `migrations/20260720230000_g1_phase5b_catalog_inventory_rls.sql` | `e427d83c34941f11e18c30454621eb8d6ccc558d657aea028e170f885085976a` | G1 phase 5B | COMPLETE; DB TEST + LOCAL APP SMOKE PASS | G1 phase 5A complete | `docs/runbooks/G1_PHASE5B_CATALOG_INVENTORY_RLS_ROLLOUT.md` |
| `20260721090000` | `migrations/20260721090000_g1_phase5c_transaction_rls.sql` | `b827f1114d3f1cae394d205f482f7b7ea28e90ec59574440b0e0c6f61ced2cf0` | G1 phase 5C | COMPLETE; DB TEST + POS/BACKOFFICE SMOKE PASS | G1 phase 5B complete | `docs/runbooks/G1_PHASE5C_TRANSACTION_RLS_ROLLOUT.md` |
| `20260721120000` | `migrations/20260721120000_g1_phase5d_finance_rls.sql` | `aec519d36b28282e0f314f4af1db546daabdc17808578cca307b73ad9d86d70f` | G1 phase 5D | COMPLETE; DB TEST + POS/BACKOFFICE SMOKE PASS | G1 phase 5C complete | `docs/runbooks/G1_PHASE5D_FINANCE_RLS_ROLLOUT.md` |
| `20260721150000` | `migrations/20260721150000_g1_phase5e_inventory_operation_rls.sql` | `265a9c2af7f19986539e5f29966838b719c324e2f517ef9cf49f78b6081c9356` | G1 phase 5E | COMPLETE; DB TEST + POS/BACKOFFICE SMOKE PASS | G1 phase 5D complete | `docs/runbooks/G1_PHASE5E_INVENTORY_OPERATION_RLS_ROLLOUT.md` |
| `20260721180000` | `migrations/20260721180000_g2_phase1_master_data_foundation.sql` | `88f695589c86171794229678c7a807645bc0b66af7ac4df696d908989e7a612c` | G2 phase 1 | COMPLETE; DB POSTFLIGHT + BEHAVIORAL TEST PASS | G1 closed; G2 master preflight PASS with zero legacy rows | `docs/runbooks/G2_PHASE1_MASTER_DATA_FOUNDATION_ROLLOUT.md` |
| `20260721210000` | `migrations/20260721210000_g2_phase4_atomic_product_crud.sql` | `19d2ddcd679a97a85db13b61461b1971726d59869c6152fffaa9d3d10cc196f2` | G2 phase 4 | COMPLETE; DB POSTFLIGHT + BEHAVIORAL TEST PASS | G2 phase 1-3 complete; Product preflight clean with zero legacy Product rows | `docs/runbooks/G2_PHASE4_ATOMIC_PRODUCT_CRUD_ROLLOUT.md` |
| `20260721230000` | `migrations/20260721230000_g2_phase6_supplier_foundation.sql` | `2200d9e48c4e40adc265bf2c4799e7f5a1d748406fe98c45a6bfd830f09434b9` | G2 phase 6 | COMPLETE | Migration, 9-row postflight, and behavioral test passed in Supabase; user confirmed all good | `docs/runbooks/G2_PHASE6_SUPPLIER_FOUNDATION_ROLLOUT.md` |
| `20260722010000` | `migrations/20260722010000_g2_phase8_customer_foundation.sql` | `f829aba7b300e934c78dd90d26c71a4410eee309f22e34c71197ae33828e5c81` | G2 phase 8 | COMPLETE | User confirmed migration success, 13/13 postflight PASS, and behavioral test PASS | `docs/runbooks/G2_PHASE8_CUSTOMER_FOUNDATION_ROLLOUT.md` |
| `20260722040000` | `migrations/20260722040000_g2_phase10_customer_grouping.sql` | `9e48aff5d737f364bea5bd4c36a39de6c9d16a0eb06026b85d6eaccd4fa2b004` | G2 phase 10 | DATABASE COMPLETE; UI FIX READY FOR SMOKE | User confirmed preflight, migration, postflight, and behavioral test all PASS; nested PostgREST self-embed removed from API after runtime smoke exposed schema-cache resolution error | `docs/runbooks/G2_PHASE10_CUSTOMER_GROUPING_UX_ROLLOUT.md` |
| `20260722070000` | `migrations/20260722070000_g2_phase12_pricelist_foundation.sql` | `e4ff626f63b29831458720284bd32a54c8059a1080087bf3845b7b68bd336765` | G2 phase 12 | COMPLETE; DB POSTFLIGHT + BEHAVIORAL TEST PASS | User confirmed migration, all 12 postflight checks, and behavioral test PASS | `docs/runbooks/G2_PHASE12_PRICELIST_FOUNDATION_ROLLOUT.md` |
| `20260722080000` | `migrations/20260722080000_g2_phase13_pricelist_default_guard.sql` | `f4ce6948824014c97666ab30c451ac24bddd211c3f99aed9fac5767287878b43` | G2 phase 13 | COMPLETE; 6 POSTFLIGHT + BEHAVIORAL TEST PASS | User confirmed forward migration, all 6 postflight checks, and default handover guard test PASS | `docs/runbooks/G2_PHASE13_PRICELIST_DEFAULT_GUARD_ROLLOUT.md` |
| `20260722100000` | `migrations/20260722100000_g2_phase13_reusable_customer_pricelist.sql` | `ae36d0a78458c3579be56bd28305142815d5709a650317535024a5c9faae6e25` | G2 phase 13 forward fix | COMPLETE; DB POSTFLIGHT + TEST + UI SMOKE PASS | User confirmed migration, 12/12 postflight, behavioral test, and reusable Customer assignment smoke | `docs/runbooks/G2_PHASE13_REUSABLE_CUSTOMER_PRICELIST_ROLLOUT.md` |
| `20260722120000` | `migrations/20260722120000_g2_phase14_payment_method_foundation.sql` | `5015d6c23862869690f801c3e53fdd673a5fc836cea24629aa542252dbdb56e3` | G2 phase 14 | COMPLETE; DB POSTFLIGHT + BEHAVIORAL TEST PASS | Initial pending-trigger failure rolled back; ordering fix applied; user confirmed rerun, 13/13 postflight, and behavioral test all PASS | `docs/runbooks/G2_PHASE14_PAYMENT_METHOD_FOUNDATION_ROLLOUT.md` |
| `20260722150000` | `migrations/20260722150000_g2_phase16_finance_master_foundation.sql` | `6b4f39ba3902f9fa7a5938d740338ed905761024b4105cfadea5f02be6308628` | G2 phase 16 | APPLIED; FINANCE MASTER MENU LOAD PASS | User resolved missing-table state by applying/reloading phase-16 schema and confirmed menu safe; exact postflight/test output was not retranscribed | `docs/runbooks/G2_PHASE16_FINANCE_MASTER_FOUNDATION_ROLLOUT.md` |
| `20260722180000` | `migrations/20260722180000_g2_phase18_required_transaction_categories.sql` | `3b79fba36beec04984097ddee0350af60cc03495c5c03e823a50d67f58f69a0d` | G2 phase 18 | COMPLETE; POSTFLIGHT + BEHAVIORAL TEST PASS | 26 required categories provisioned; corrected 11-row postflight and rerun behavioral test confirmed by user after phase-19 fix | `docs/runbooks/G2_PHASE18_REQUIRED_TRANSACTION_CATEGORIES_ROLLOUT.md` |
| `20260722210000` | `migrations/20260722210000_g2_phase19_finance_history_trigger_fix.sql` | `5a713c7f7d58e1936d466fd1b97f96f98c0cb454f0c3de53477934e288fd9dc2` | G2 phase 19 | COMPLETE; 5 POSTFLIGHT + REGRESSION PASS | User confirmed forward migration, all postflight checks, dedicated regression, and rerun phase-18 behavioral test PASS | `docs/runbooks/G2_PHASE19_FINANCE_HISTORY_TRIGGER_FIX_ROLLOUT.md` |
| `20260722230000` | `migrations/20260722230000_g2_phase20_guarded_coa_fallback.sql` | `3ba740631d688ad759ea0f973e1bc220c7a2c386be8ee45405f85898ad16df37` | G2 phase 20 | COMPLETE; 8 POSTFLIGHT + BEHAVIORAL TEST + UI SMOKE PASS | User confirmed the full rollout and smoke as all good; COA/fallback guard remains master-only and Finance posting stays disabled | `docs/runbooks/G2_PHASE20_GUARDED_COA_FALLBACK_ROLLOUT.md` |
| `20260723010000` | `migrations/20260723010000_g2_phase22_tax_master_foundation.sql` | `4745d45c46e49ba4901c2c866dc2df8a905839c4bc8b2212244d001f11503e7c` | G2 phase 22 | COMPLETE; 14 POSTFLIGHT + BEHAVIORAL TEST + COMPATIBILITY SMOKE PASS | User confirmed full rollout all pass; effective Tax master remains resolver/posting-disabled | `docs/runbooks/G2_PHASE22_TAX_MASTER_FOUNDATION_ROLLOUT.md` |
| `20260723040000` | `migrations/20260723040000_g2_phase26_guarded_tax_assignment.sql` | `39578cb4c25f506da849c1891bf8c71443466ab210acc2ff887c0dbe30cc3e17` | G2 phase 26 | COMPLETE; POSTFLIGHT + BEHAVIORAL TEST PASS | User confirmed all pass; Category/Product assignment guarded and audited; resolver remains disabled | `docs/runbooks/G2_PHASE26_GUARDED_TAX_ASSIGNMENT_ROLLOUT.md` |
| `20260723070000` | `migrations/20260723070000_g2_phase28_tax_resolver_calculator.sql` | `0047f2577fb4538a386cd2ddb5011cdcde78081c003593568c8291dbcf09af17` | G2 phase 28 | COMPLETE; POSTFLIGHT + BEHAVIORAL TEST PASS | User confirmed full rollout all pass; private resolver/calculator active, transaction cutover remains disabled | `docs/runbooks/G2_PHASE28_TAX_RESOLVER_CALCULATOR_ROLLOUT.md` |
| `20260723100000` | `migrations/20260723100000_g2_phase30_master_import_staging_foundation.sql` | `ff501ea85eb2711db94628afa6a946a43c9f3d849ebc4fae5f7f412bb0ec7d17` | G2 phase 30 | COMPLETE; 11 POSTFLIGHT + BEHAVIORAL TEST PASS | User confirmed full rollout all pass; non-stock staging active, validation/commit/stock remain separate | `docs/runbooks/G2_PHASE30_MASTER_IMPORT_STAGING_FOUNDATION_ROLLOUT.md` |
| `20260723130000` | `migrations/20260723130000_g2_phase31_master_import_identity_validator.sql` | `8058646027141760a1fc201224b0f2b1a6acc92174c5dfe4472064dcbc951eb6` | G2 phase 31 | COMPLETE; 8 POSTFLIGHT + BEHAVIORAL TEST PASS | User confirmed full rollout all pass; deterministic common identity/lifecycle preview active and commit remains disabled | `docs/runbooks/G2_PHASE31_MASTER_IMPORT_IDENTITY_VALIDATOR_ROLLOUT.md` |
| `20260723160000` | `migrations/20260723160000_g2_phase32_master_import_business_validator.sql` | `b31ad5d37fef58c7bf105425d2240d4b2d54961eac895231d8a982e4f0e46731` | G2 phase 32 | COMPLETE; 7 POSTFLIGHT + BEHAVIORAL TEST PASS | User confirmed full rollout all pass; business-field preview active and commit remained disabled for this phase | `docs/runbooks/G2_PHASE32_MASTER_IMPORT_BUSINESS_VALIDATOR_ROLLOUT.md` |
| `20260723190000` | `migrations/20260723190000_g2_phase33_master_import_partial_commit.sql` | `2caa5c0585f3b228953eb731295b539d37a61c00c70f2f3b3410b7becd69888d` | G2 phase 33 | COMPLETE; POSTFLIGHT + BEHAVIORAL TEST PASS | User confirmed guarded partial commit all pass; Product and stock remain excluded | `docs/runbooks/G2_PHASE33_MASTER_IMPORT_PARTIAL_COMMIT_ROLLOUT.md` |
| `20260724010000` | `migrations/20260724010000_g2_phase36_automatic_master_codes.sql` | `21915046fb33c186a6469d2b9db46857fcf4d72d496f39c895ef3a070a44e2cb` | G2 phase 36 | COMPLETE; 11 POSTFLIGHT + BEHAVIORAL TEST PASS | User confirmed automatic immutable tenant-scoped technical codes all pass; existing code preserved | `docs/runbooks/G2_PHASE36_AUTOMATIC_MASTER_CODES_ROLLOUT.md` |
| `20260724040000` | `migrations/20260724040000_g2_phase38_codeless_master_import.sql` | `840a1a509d26978a43dadc99fe641fcc38a14ed99d80e5245a3fa47d170c4a05` | G2 phase 38 | COMPLETE; 7 POSTFLIGHT + BEHAVIORAL TEST PASS | User confirmed code-less server validation and legacy CSV compatibility all pass | `docs/runbooks/G2_PHASE38_CODELESS_MASTER_IMPORT_ROLLOUT.md` |
| `20260727090000` | `migrations/20260727090000_g2_phase40_remaining_simple_master_import.sql` | `688fa03c08a3816c9acfb01c5d6dd7c316c8c20495dd6d5bd17171a1599d33d8` | G2 phase 40 | COMPLETE | Main migration, 10-check postflight, behavioral test, dan Phase-38 compatibility regression dikonfirmasi PASS setelah forward fix | `docs/runbooks/G2_PHASE40_REMAINING_SIMPLE_MASTER_IMPORT_ROLLOUT.md` |
| `20260727100000` | `migrations/20260727100000_g2_phase40_coa_parent_uuid_aggregate_fix.sql` | `1c628632187d0400da214b87eac8e297d8dcd5790a8b584a5f86e420b080810a` | G2 phase 40 forward fix | COMPLETE | Replaces unsupported `min(uuid)` with deterministic `min(id::text)::uuid`; user confirmed 4-check postflight and behavioral/regression tests PASS | `docs/runbooks/G2_PHASE40_COA_PARENT_UUID_AGGREGATE_FIX.md` |

Migration berikutnya tidak boleh memakai timestamp/version yang lebih rendah dan tidak boleh mengedit file di atas setelah applied.

Penutupan terintegrasi G1 dikonfirmasi pada 2026-07-21 melalui 15/15 closure
preflight `PASS`, integrated negative-access test `PASS`, dan local Backoffice
smoke `PASS`. Evidence: `docs/audits/G1_SECURITY_CLOSURE_2026-07-21.md`.

G2 dimulai dari diagnostic SELECT-only untuk menginventarisasi backfill master
legacy. Diagnostic bukan migration dan tidak dicatat ke ledger.
