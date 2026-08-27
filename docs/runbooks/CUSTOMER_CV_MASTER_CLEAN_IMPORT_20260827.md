# Import Customer CV Master Clean — file CSV per Company

## File

- `data/import/customer_cv_20260827/customer_import_KMS_20260827.csv` — 20 Customer baru;
- `data/import/customer_cv_20260827/customer_import_LSM_20260827.csv` — 16 Customer baru;
- `data/import/customer_cv_20260827/customer_import_SMS_20260827.csv` — 9 Customer baru.

File hanya memuat kode yang belum ada pada Company tujuan berdasarkan audit
read-only 27 Agustus 2026. Customer existing tidak disertakan dan tidak akan
diubah oleh file ini.

## Cara import

Lakukan satu Company pada satu waktu:

1. pilih Workspace/Company yang sesuai dengan nama file;
2. buka **Data Exchange → Import data**;
3. pilih jenis master **Customer**;
4. pilih **Cocokkan berdasarkan nama**;
5. pilih tindakan **Hanya buat data baru**;
6. upload CSV Company tersebut;
7. pastikan mapping otomatis mengenali `code`, `name`,
   `customer_category_name`, `address`, `customer_type`, `credit_limit`, dan
   `is_active`;
8. validasi, tetapi jangan simpan jika ada baris `UPDATE` atau `ERROR`;
9. hasil valid yang diharapkan seluruhnya `CREATE`: KMS 20, LSM 16, SMS 9;
10. konfirmasi simpan hanya setelah jumlah tersebut cocok.

## Catatan nama unik

KMS memiliki empat kode dengan nama sumber sama, `Dedi Supriadi`. Karena nama
Customer wajib unik per Company, file menggunakan:

- `Dedi Supriadi (A18)`;
- `Dedi Supriadi (B11)`;
- `Dedi Supriadi (B12)`;
- `Dedi Supriadi (I11)`.

Kode Customer tetap sesuai workbook.

## Arsip Customer lama lintas Company

CSV hanya membuat Customer baru dan tidak mengarsipkan data Company lain.
Setelah KMS dan SMS berhasil diimport, buka Customer LSM dan nonaktifkan secara
manual kode berikut jika tetap tidak memiliki transaksi/saldo:

- `C03`, `H08`, dan `H12` setelah replacement KMS tersedia;
- `H17` setelah replacement SMS tersedia.

Jangan hapus permanen. Audit read-only awal menyatakan keempat record belum
memiliki transaksi, saldo, child Customer, atau Customer Pricelist, tetapi
periksa kembali pada saat arsip dilakukan.
