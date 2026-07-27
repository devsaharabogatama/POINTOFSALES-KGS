# G2 Phase 26 — Guarded Product/Category Tax Assignment Rollout

## Boundary

Rollout ini hanya membangun boundary penyimpanan assignment Tax Rule untuk
Product Category dan override Product. Rollout ini **tidak** mengaktifkan:

- resolver Category → Product → transaction;
- kalkulasi Tax pada checkout/Purchase;
- Tax snapshot transaksi;
- Finance posting, reversal, report, atau dokumen pajak.

## Hasil Preflight yang Disetujui

Preflight `g2_phase26_tax_assignment_preflight.sql` diterima tanpa blocker:

- seluruh invariant assignment `PASS`;
- satu Company aktif, satu Product, dan satu Category;
- belum ada Tax Rule maupun assignment;
- entitlement Sales/Purchase Tax masih nonaktif;
- direct Product write sudah tertutup;
- Category masih memiliki direct table `UPDATE`, sehingga kolom Tax harus
  ditutup dengan column-level privilege.

## Urutan Manual Supabase

Jalankan satu per satu di Supabase SQL Editor:

1. migration:

   ```text
   supabase/migrations/20260723040000_g2_phase26_guarded_tax_assignment.sql
   ```

2. postflight:

   ```text
   supabase/diagnostics/g2_phase26_guarded_tax_assignment_postflight.sql
   ```

   Expected: seluruh row `PASS` dan `violation_rows = 0`.

3. behavioral test:

   ```text
   supabase/tests/g2_phase26_guarded_tax_assignment_tests.sql
   ```

   Expected notice:

   ```text
   TEST PASSED: Product Category/Product Tax assignments are tenant-safe, effective-version guarded, optimistic, audited, and atomic with Product-UOM saves.
   ```

Kirim seluruh output postflight dan hasil behavioral test sebelum UI assignment
diaktifkan.

## Invariant Server-side

- assignment hanya untuk Company aktif pada request context;
- actor wajib Catalog Manager;
- assignment non-null memerlukan entitlement scope aktif;
- Tax Rule wajib aktif, scope tepat, dan memiliki tepat satu versi `ACTIVE`
  yang efektif sekarang;
- clearing assignment tetap diizinkan ketika entitlement sudah dimatikan;
- stale `master_version` ditolak;
- perubahan assignment dicatat before/after;
- Product + Product-UOM + Tax override tersedia sebagai satu overload RPC dan
  rollback bersama jika salah satu validasi gagal;
- browser tidak memiliki direct write ke kolom Tax Category maupun tabel audit.

## Compatibility

- RPC Product 12-argument lama dipertahankan agar UI existing tetap berjalan;
- overload 14-argument dipakai saat UI Tax Product diaktifkan;
- Category create/edit existing tetap berjalan melalui column-level grant untuk
  `company_id`, kode, nama, dan status;
- assignment Tax Category hanya melalui guarded RPC;
- tidak ada data bisnis yang dibackfill karena preflight menunjukkan nol
  assignment.

## Forward-fix Note

Migration applied tidak boleh diedit. Jika rollout gagal setelah commit, buat
forward migration baru. Karena seluruh migration berada dalam satu transaksi,
error sebelum `COMMIT` akan membatalkan seluruh perubahan fase ini.

## Next Safe Step

Setelah migration, postflight, dan test PASS:

1. tampilkan pilihan Tax Sales/Purchase pada Category;
2. tampilkan inheritance Category dan override opsional pada Product;
3. gunakan nama Tax Rule, bukan UUID/kode internal, pada UI;
4. sembunyikan/disable input sesuai entitlement;
5. lakukan lint, build, dan smoke menu Category/Product;
6. resolver transaksi tetap ditunda ke fase terpisah.
