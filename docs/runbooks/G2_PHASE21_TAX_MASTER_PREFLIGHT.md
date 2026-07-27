# G2 Phase 21 Tax Master Preflight

## Tujuan

Mengaudit kesiapan Master Tax Sales/Purchase sebelum schema atau UI dibuat.
Audit mencakup entitlement independen, akun Pajak Masukan/Keluaran, Product dan
Category assignment, histori Sales/Purchase, serta snapshot line.

## Safety

File `supabase/diagnostics/g2_phase21_tax_master_preflight.sql` hanya memakai
`SELECT`. Audit tidak:

- mengaktifkan `tax_sales_enabled` atau `tax_purchase_enabled`;
- membuat Tax Rule atau menempelkan rule ke Product/Category;
- mengubah Sales/Purchase history;
- menghitung pajak, mengubah checkout, atau membuat jurnal;
- mengklaim integrasi e-Faktur/kepatuhan pemerintah.

## Cara Menjalankan

1. Buka SQL Editor Supabase.
2. Jalankan seluruh isi
   `supabase/diagnostics/g2_phase21_tax_master_preflight.sql`.
3. Kirim semua baris `check_name,status,details`.
4. Jangan lanjut migration bila ada `BLOCKER`.

## Interpretasi

- `canonical_tax_schema_state`, assignment, dan snapshot berstatus `INFO` serta
  masih missing adalah expected sebelum foundation Tax.
- Kedua entitlement boleh sama-sama off, hanya Sales aktif, hanya Purchase
  aktif, atau keduanya aktif.
- Entitlement aktif tanpa akun compatible adalah `BLOCKER` karena sistem tidak
  boleh menebak akun.
- Duplicate akun fungsi Tax dan total legacy negatif memerlukan `REVIEW`.
- Histori transaksi bukan otomatis blocker, tetapi menentukan kebutuhan
  compatibility/backfill. Data posted tidak boleh dihitung ulang diam-diam.

## Boundary Berikutnya

Jika bersih, phase berikut hanya boleh membangun Master Tax effective-dated,
assignment nullable, snapshot nullable, guarded RPC/RLS/audit, dan UI master.
Tax resolver checkout, Supplier Invoice calculation, return/reversal, journal,
dan official tax reporting tetap deferred ke gate operasional terkait.

