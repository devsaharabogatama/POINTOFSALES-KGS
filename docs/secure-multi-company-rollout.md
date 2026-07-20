# Secure Multi-Company Rollout

## 1. Backup

Ambil backup database Supabase sebelum menjalankan migrasi. Jangan menjalankan file test pada database production.

## 2. Terapkan SQL berurutan

1. `supabase/migrations/002_secure_tenant_product_weight_import.sql`
2. `supabase/policies.sql`
3. `supabase/checkout_rpc.sql`
4. `supabase/fix_permissions.sql`

## 3. Tetapkan platform super admin

Jalankan satu kali dengan email akun platform yang benar:

```sql
update public.profiles
set role = 'super_admin'::user_role
where email = 'GANTI_DENGAN_EMAIL_ADMIN';
```

Pastikan tepat satu akun yang terpengaruh. Jangan memberikan `super_admin` kepada akun operasional tenant.

## 4. Rekonsiliasi data test

Database yang diaudit memiliki tenant `KGS`, `COMP-A`, dan `COMP-B`. Sebelum menghapus tenant test:

1. Tentukan company yang menjadi tenant bisnis resmi.
2. Pindahkan membership akun operasional ke company resmi.
3. Pastikan produk, warehouse, store, dan transaksi sudah dimapping.
4. Hapus `COMP-A`/`COMP-B` hanya setelah backup dan verifikasi bahwa keduanya memang fixture test.

## 5. Verifikasi

- Super admin dapat melihat seluruh company dan mengganti workspace.
- Company owner hanya melihat company membership-nya.
- Company owner tidak dapat membuat staf untuk company lain.
- User biasa tidak dapat mengubah `profiles.role`.
- SKU, kode gudang, kode customer, dan kode UOM yang sama dapat digunakan pada company berbeda.
- Import ulang dengan stok awal yang sama tidak menggandakan stok atau batch.
- Import ulang dengan stok awal berbeda ditolak dan diarahkan ke stock adjustment.
- Berat pengiriman dihitung dengan `qty * products.weight_per_uom_kg`.
