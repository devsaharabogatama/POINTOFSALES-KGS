# Runbook G1 Fase 2 — Core Tenant Consistency

**Migration:** `supabase/migrations/20260720120000_g1_phase2_core_tenant_consistency.sql`  
**Requirement:** TEN-001  
**Scope:** Store, POS Terminal, Store Membership, Product, UOM, Bundle, Warehouse Stock, UOM Conversion, dan Product Batch.

## Yang Berubah

- Empat parent master memperoleh unique key `(company_id, id)` untuk referensi tenant-safe.
- Dua belas composite foreign key memastikan child dan parent selalu berada pada Company yang sama.
- Index child ditambah untuk mencegah parent update/delete melakukan full scan.
- Foreign key ID lama dipertahankan untuk kompatibilitas.
- Tidak ada UI, enum, data bisnis, price, stock quantity, atau workflow yang diubah.

Migration menambah FK kedua antara beberapa pasangan table. PostgREST embed wajib menyebut relationship hint agar tidak menghasilkan `PGRST201` ambiguous relationship. Compatibility patch menggunakan nama FK legacy sehingga query bekerja sebelum dan sesudah migration:

- `backoffice/src/app/page.tsx` untuk Product → Stock → Warehouse;
- `pwa/src/lib/sync.ts` untuk sinkronisasi Product → Stock.

Deploy compatibility patch segera setelah migration dan lakukan smoke test. Jangan menghapus composite FK sebagai cara memperbaiki ambiguity API.

Sales/Purchase/Finance transaction topology belum termasuk migration ini.

## Urutan Manual

1. Pastikan migration G1 fase 1 dan smoke test sudah PASS.
2. Jalankan `supabase/diagnostics/g1_phase2_core_tenant_preflight.sql`.
3. Semua 12 relation wajib `PASS` dengan `mismatch_rows = 0`.
4. Ambil backup/export dan jalankan pada trafik rendah karena pembuatan unique index/validation dapat mengambil lock singkat.
5. Jalankan seluruh migration sebagai satu batch. Jangan menjalankan per bagian.
6. Jalankan `supabase/diagnostics/g1_phase2_core_tenant_postflight.sql`; seluruh baris wajib `PASS`.
7. Jalankan `supabase/tests/g1_phase2_core_tenant_constraints_tests.sql`; test wajib menghasilkan notice `TEST PASSED` dan selalu `ROLLBACK`.
8. Smoke test frontend: Product list/detail, UOM, Warehouse/Stock read, serta import Product bila tersedia.

## Stop Condition

- Preflight mismatch lebih dari nol: jangan migration dan jangan mengubah `company_id` otomatis.
- Migration error: simpan error lengkap; transaction seharusnya rollback seluruh perubahan.
- Postflight/test gagal: jangan lanjut ke transaction topology.
- Regression frontend: catat request/API dan exact status; jangan menghapus constraint sebagai quick fix.

## Rollback / Forward Fix

Constraint ini menjaga invariant data dan tidak dirancang untuk dibuang setelah write baru berlangsung. Jika integration lama mengirim parent lintas Company, perbaiki resolver/request integration tersebut. Hanya buat forward migration setelah sumber mismatch terbukti.
