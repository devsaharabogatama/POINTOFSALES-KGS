# Supabase Migration Manifest — G0 Baseline

**Status:** G0 CLOSED; canonical forward chain dimulai dari `20260720090000`  
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
| `20260720120000` | `migrations/20260720120000_g1_phase2_core_tenant_consistency.sql` | `166c5a071cc78e62f8e708ab4f5c75e9847082e0e1a5e25613d2f110bf961cd5` | G1 phase 2 | READY FOR MANUAL PREFLIGHT/APPLY | G1 phase 1 complete | `docs/runbooks/G1_PHASE2_CORE_TENANT_ROLLOUT.md` |

Migration berikutnya tidak boleh memakai timestamp/version yang lebih rendah dan tidak boleh mengedit file di atas setelah applied.
