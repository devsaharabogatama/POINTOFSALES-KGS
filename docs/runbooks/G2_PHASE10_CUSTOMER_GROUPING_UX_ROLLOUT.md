# Runbook G2 Fase 10 - Customer Grouping dan UX Consistency

**Status:** DATABASE COMPLETE — READY FOR UI SMOKE RETRY  
**Dependency:** `20260722010000` complete

**Preflight evidence:** user mengonfirmasi seluruh check `PASS`. Error schema
cache self-relationship pada menu Customer sebelum rollout adalah expected
karena FK `fk_customers_company_parent` belum dibuat sampai migration dijalankan.

**Database evidence:** user mengonfirmasi migration, postflight, dan behavioral
test seluruhnya PASS. Setelah rollout, PostgREST tetap gagal melakukan nested
self-embed `customers -> customers`; API diperbaiki agar memakai
`parent_customer_id` dari result Customer yang sama tanpa nested self-join.

## Scope

- UOM operasional ditampilkan dengan nama, bukan kode internal;
- dashboard mengambil nama canonical Base UOM;
- tombol `Esc` menutup modal Backoffice utama;
- uniqueness normalized kode/nama tetap diblokir server-side; fase ini
  menambahkan normalized UOM-code dan Warehouse-name unique index yang belum
  eksplisit;
- Customer dapat mempunyai satu Customer induk untuk roll-up laporan;
- transaksi, saldo, limit, dan histori tetap melekat pada Customer anak;
- hierarki dibatasi satu tingkat dan cross-Company/cycle ditolak.

## Urutan Manual

1. Jalankan `supabase/diagnostics/g2_phase10_customer_grouping_preflight.sql`.
2. Semua baris berstatus selain `INFO` harus `PASS`. Jika ada `BLOCKER`, stop
   dan kirim hasil lengkap; jangan jalankan migration.
3. Setelah disetujui, jalankan
   `supabase/migrations/20260722040000_g2_phase10_customer_grouping.sql` sekali.
4. Jalankan `supabase/diagnostics/g2_phase10_customer_grouping_postflight.sql`;
   expected seluruhnya `PASS`.
5. Jalankan `supabase/tests/g2_phase10_customer_grouping_tests.sql`; expected
   notice `TEST PASSED`.
6. Restart Backoffice, lalu smoke:
   - daftar UOM dan seluruh pilihan Product/Supplier memakai nama satuan;
   - `Esc` menutup modal Product, master, Supplier, Customer, Staff, Company,
     dan grouping;
   - dua Customer dapat dihubungkan sebagai induk/cabang;
   - cabang tampil di kartu induk dan dapat dilepas kembali;
   - menu existing tetap dapat dibuka.

## Stop Condition

- Migration tidak boleh dijalankan sebelum preflight bersih.
- Setelah applied, file migration tidak boleh diedit.
- Jangan membuat hierarki lebih dari satu tingkat.
- Jangan memindahkan `sales_headers.customer_id`, saldo, atau histori transaksi
  ke Customer induk.
