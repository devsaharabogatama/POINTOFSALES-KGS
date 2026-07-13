# Multi-Company Migration Runbook

Panduan teknis dan urutan langkah aman untuk melakukan migrasi database KGS dari single-tenant menjadi multi-tenant.

---

## 📅 Tahap 1: Persiapan & Backup (Pre-Migration)
Sebelum memulai migrasi pada basis data production, lakukan backup skema dan data:
```bash
# Melakukan backup database Supabase menggunakan CLI
supabase db dump --data-only > backup_data.sql
supabase db dump --schema-only > backup_schema.sql
```

---

## 🚀 Tahap 2: Eksekusi File Migrasi (Migration Execution)
Eksekusi berkas migrasi Supabase `supabase/migrations/001_multi_company_setup.sql` yang melakukan langkah berikut secara berurutan:

1. **Membuat Tabel Tenant Core**:
   * Menambahkan tabel `companies`, `stores`, `pos_terminals`, `company_memberships`, `store_memberships`.
2. **Menambahkan Kolom Tenant**:
   * Menambahkan kolom `company_id` (UUID, NULLABLE) pada tabel-tabel master data dan transaksi.
   * Menambahkan kolom `store_id` (UUID, NULLABLE) pada tabel-tabel transaksi.
3. **Membuat Company Default (KGS)**:
   * Menambahkan baris perusahaan default KGS ke tabel `companies`.
   * Menambahkan baris toko default KGS ke tabel `stores`.
   * Menambahkan baris terminal POS default ke tabel `pos_terminals`.
4. **Proses Backfill Data Lama**:
   * Memperbarui seluruh baris tabel lama agar kolom `company_id` mengarah pada ID perusahaan KGS.
   * Memperbarui `sales_headers` dan `cashier_sessions` agar kolom `store_id` dan `pos_id` mengarah pada toko/POS default KGS.
5. **Pemberlakuan Batasan (Constraints & Indexes)**:
   * Mengubah batasan kolom `company_id` dari `NULLABLE` menjadi `NOT NULL`.
   * Memasang index komposit baru ber-prefix `company_id` untuk optimasi pencarian tenant.
   * Mengaktifkan Row Level Security (RLS) dengan filter isolasi tenant.

---

## 🔍 Tahap 3: Uji Validasi Migrasi (Validation)
Jalankan query audit berikut untuk memastikan tidak ada data tenant yang bocor atau tidak ter-backfill:
```sql
-- Pastikan tidak ada kolom company_id yang bernilai NULL
SELECT table_name 
FROM information_schema.columns 
WHERE column_name = 'company_id' 
  AND is_nullable = 'YES';
```

---

## ↩️ Tahap 4: Rencana Rollback (Rollback Plan)
Jika terjadi kegagalan sistem setelah migrasi berjalan, ikuti prosedur berikut:
1. Matikan koneksi server API Next.js / PWA untuk mencegah penulisan data baru.
2. Restore database Supabase dari backup pra-migrasi:
   ```bash
   supabase db reset
   psql -h db.supabase.co -U postgres -d postgres -f backup_schema.sql
   psql -h db.supabase.co -U postgres -d postgres -f backup_data.sql
   ```
3. Nyalakan kembali server API.
