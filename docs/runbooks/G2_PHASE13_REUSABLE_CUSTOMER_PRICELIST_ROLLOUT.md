# G2 Phase 13 — Reusable Customer Pricelist Rollout

## Outcome

Memindahkan ownership assignment dari header Pricelist ke Customer sehingga
satu Pricelist khusus dapat digunakan banyak Customer.

## Urutan manual

1. Jalankan
   `supabase/migrations/20260722100000_g2_phase13_reusable_customer_pricelist.sql`.
2. Jalankan
   `supabase/diagnostics/g2_phase13_reusable_customer_pricelist_postflight.sql`.
   Expected: **12 PASS**.
3. Jalankan
   `supabase/tests/g2_phase13_reusable_customer_pricelist_tests.sql`.
   Expected notice: `TEST PASSED`.
4. Restart Backoffice.
5. Buat satu Pricelist `Khusus Customer`.
6. Edit dua Customer berbeda dan pilih Pricelist yang sama.
7. Pastikan daftar Customer menampilkan nama Pricelist yang sama.

## Compatibility

- Migration applied lama tidak diedit.
- `pricelists.customer_id` dipertahankan nullable sebagai compatibility column,
  tetapi wajib `NULL` dan tidak lagi menjadi assignment.
- RPC lama `save_pricelist_with_rules` ditutup untuk browser.
- Product-UOM fallback, Sales snapshot, dan checkout lama tidak berubah.
- Resolver pricing tetap deferred ke G4.

## Forward-fix / rollback

Jangan rollback DDL setelah Customer mulai menyimpan assignment. Bila ada
masalah runtime, lepaskan assignment melalui guarded Customer RPC atau buat
forward migration. Database transaction migration sendiri rollback otomatis
bila guard atau DDL gagal sebelum `COMMIT`.
