# Duplikasi Konfigurasi Finance Antar-Company

Operasi ini digunakan ketika Company baru membutuhkan struktur COA dan mapping
Finance yang sama dengan Company sumber, tanpa menyalin histori maupun saldo.

## Cakupan

File operasi:
[`supabase/operations/clone_company_finance_configuration.sql`](../../supabase/operations/clone_company_finance_configuration.sql)

Disalin dengan UUID baru milik Company tujuan:

- COA dan hierarki parent;
- Transaction Category;
- current active Transaction Account Rule;
- current active Account Function Fallback;
- current approved Posting Rule Set beserta expression lines.

Tidak disalin:

- Financial Event, Journal, saldo awal, Stock, FIFO, transaksi atau dokumen;
- Customer, Supplier, Product, user, membership dan custom permission;
- identitas Company, rekening, branding dan feature entitlement;
- Payment Method, Tax Rule, Expense policy, Offline/negative-stock policy;
- setting yang menunjuk Store, Warehouse, Terminal, Session atau user sumber.

## Prasyarat

1. Backup database tersedia.
2. Company sumber dan tujuan berbeda dan berstatus aktif.
3. Company tujuan belum mempunyai Financial Event atau Journal.
4. Actor audit adalah Super Admin, atau Owner/Admin aktif pada kedua Company.

Jika salah satu prasyarat tidak terpenuhi, operasi berhenti tanpa perubahan.

## Mendapatkan UUID Company

Jalankan read-only query berikut di Supabase SQL Editor:

```sql
SELECT id,company_code,company_name,status
FROM public.companies
WHERE lower(company_name) LIKE ANY(ARRAY['%kgs%','%kms%'])
ORDER BY company_name;
```

Gunakan `company_name` persis dari hasil database. Pemeriksaan nama mencegah
UUID Company tertukar.

## Urutan eksekusi

1. Buka file operasi dan isi `source_company_id`, `source_company_name`,
   `target_company_id`, dan `target_company_name` pada satu blok konfigurasi.
2. Biarkan `actor_id = NULL` agar operasi memilih linked Super Admin pertama,
   atau isi UUID actor secara eksplisit.
3. Biarkan `execute_clone = FALSE` dan `confirmation = NULL`.
4. Jalankan seluruh file. Hasil wajib tidak memiliki `BLOCKER` dan baris
   `operation_mode` harus berstatus `PREVIEW` dengan `writesExecuted=false`.
   Status `REPLACE` pada baseline mapping dan `REMAP` pada system account
   diperbolehkan hanya ketika `target_financial_history=PASS`.
5. Ubah hanya:

   ```sql
   TRUE,
   'CLONE_FINANCE_CONFIGURATION'
   ```

6. Jalankan seluruh file sekali lagi.
7. Hasil akhir wajib memuat `applied_configuration_verification = PASS` dan
   `operation_mode = APPLIED`.

DO block APPLY berjalan atomik. Error pada akun, parent, kategori, mapping,
expression, trigger, atau verifikasi akhir membatalkan seluruh write.

## Compatibility dan batas operasi

- Akun target dicocokkan berdasarkan normalized `account_code`; UUID sumber
  tidak pernah dipakai sebagai UUID target.
- Parent COA dipetakan setelah seluruh akun target tersedia.
- Category dicocokkan berdasarkan normalized `category_code`.
- Konflik nama memblokir APPLY. System account dengan fungsi sama tetapi kode
  berbeda memakai identitas system account target; Account ID pada mapping
  dipetakan ulang tanpa menyalin UUID sumber atau membuka system owner kedua.
- Mapping bawaan target dinonaktifkan/di-retire secara audited sebelum versi
  hasil clone diaktifkan. Mapping lama tidak dihapus.
- Akun/kategori minimum yang kodenya sama diperbarui agar sesuai sumber.
- Akun target tambahan tidak dihapus.
- Operasi bukan sinkronisasi terus-menerus. Perubahan KGS setelah clone tidak
  otomatis mengubah KMS.
- Versi mapping baru selalu memakai nomor sesudah versi target terakhir.

## Setelah clone

Lakukan smoke pada KMS:

1. buka Finance > Kategori & COA;
2. bandingkan jumlah serta hierarki akun dengan KGS;
3. buka mapping kategori transaksi dan pastikan seluruh fungsi akun resolved;
4. buat satu transaksi disposable pada KMS;
5. proses melalui Finance queue dan pastikan Journal seimbang;
6. hapus data disposable memakai prosedur reset yang sesuai hanya bila memang
   masih sebelum go-live.
