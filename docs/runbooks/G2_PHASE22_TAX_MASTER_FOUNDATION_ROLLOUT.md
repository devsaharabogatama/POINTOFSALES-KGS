# G2 Phase 22 Tax Master Foundation Rollout

## Outcome

Membangun fondasi Master Tax Sales/Purchase yang tenant-scoped dan
effective-dated tanpa mengaktifkan entitlement, kalkulasi transaksi, checkout,
Supplier Invoice Tax, return/reversal, jurnal, atau pelaporan pajak resmi.

## Evidence Preflight

User mengonfirmasi seluruh phase-21 preflight hanya berstatus `PASS` dan `INFO`.
Tidak ada `BLOCKER` atau `REVIEW` yang memerlukan keputusan/backfill historis.

## Urutan Manual Supabase

Jalankan satu file penuh per langkah:

1. `supabase/migrations/20260723010000_g2_phase22_tax_master_foundation.sql`;
2. `supabase/diagnostics/g2_phase22_tax_master_foundation_postflight.sql`;
3. pastikan tepat **14 PASS** dan seluruh `violation_rows = 0`;
4. `supabase/tests/g2_phase22_tax_master_foundation_tests.sql`;
5. pastikan notice berakhir dengan `TEST PASSED` dan menyatakan calculation/
   posting tetap disabled;
6. restart Backoffice dan buka seluruh menu existing. Fase ini belum menambah
   menu Tax, sehingga tidak boleh muncul schema-cache notification/error.

## Behavior Foundation

- `tax_rules` menyimpan identitas stabil per Company;
- `tax_rule_versions` menyimpan rate, calculation scope, price mode, account,
  recoverability, status, periode, dan nomor versi;
- Sales Tax selalu `INCLUSIVE`; Purchase Tax boleh `INCLUSIVE`/`EXCLUSIVE`;
- `is_recoverable` hanya berlaku dan wajib ditentukan untuk Purchase Tax;
- versi aktif baru menutup versi aktif lama secara atomic;
- Tax Rule hanya dapat disimpan ketika entitlement scope terkait sudah aktif;
- hanya Finance/Accounting/Company Admin/Owner/Super Admin yang dapat memakai
  RPC dalam Company aktif;
- kode dan nama Tax unik per Company;
- Product/Category assignment dan Sales/Purchase snapshot ditambah nullable;
- existing transaction tidak diisi atau dihitung ulang;
- direct browser mutation tetap ditutup dan audit before/after disimpan.

## Compatibility

- `tax_sales_enabled` dan `tax_purchase_enabled` tidak berubah;
- legacy Company `tax_id` tidak dipindahkan atau ditafsirkan otomatis;
- Product, Category, Sales, Purchase, Pricelist, Payment, dan Finance master
  existing tetap memakai flow saat ini;
- rate default tidak diprovision karena sistem tidak boleh mengasumsikan aturan
  pajak Company;
- e-Faktur, government filing, dan klaim kepatuhan bukan scope aplikasi ini.

## Rollback / Forward Fix

Migration berada dalam satu transaction; kegagalan sebelum `COMMIT` rollback
seluruh DDL. Setelah applied jangan mengedit file migration. Gunakan forward
migration untuk defect. Jangan mengisi snapshot transaksi lama atau mengaktifkan
Tax resolver sebagai cara memperbaiki rollout foundation.

