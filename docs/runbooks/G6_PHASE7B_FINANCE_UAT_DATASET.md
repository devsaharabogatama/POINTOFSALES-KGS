# G6 Phase 7B — Finance UAT Dataset

## Tujuan

Paket ini membuat data uji Finance yang mengikuti alur aplikasi, bukan menulis
langsung ke jurnal final. Dataset menggunakan Company aktif tunggal dan
menghasilkan source operasional, Stock/FIFO/Movement, Financial Event,
controlled posting queue, serta jurnal double-entry yang saling terhubung.

Dataset bersifat permanen dan hanya boleh dijalankan pada database test/pilot.
Posted Stock Movement dan jurnal tidak boleh dihapus untuk membersihkan data.

## Hasil yang Dibuat

| Data | Hasil expected |
|---|---|
| Product | `UAT-FIN-001 — UAT Finance Product` |
| Opening Stock | 100 base unit × Rp50.000 = Rp5.000.000 |
| Posting queue | satu run `PST/YYYY/MM/######`, status `COMPLETED` |
| Journal Entry | satu `JUR/YYYY/MM/######`, debit Inventory Rp5.000.000 dan credit Opening Balance Clearing Rp5.000.000 |
| Stock Adjustment | physical count 105, gain 5 base unit |
| Pending Analysis | satu `STOCK_GAIN` HOLD senilai Rp250.000, belum masuk laporan POSTED |
| Stok akhir | 105 base unit; FIFO tersisa Rp5.250.000 |

Pemisahan `POSTED` dan `HOLD` disengaja. Queue G6 saat ini hanya mendukung
`STOCK_OPENING`; script tidak membuka kontrak posting `STOCK_GAIN` yang masih
deferred.

## Urutan Menjalankan

1. Pastikan ini database UAT/pilot dan hanya ada satu Company `ACTIVE`.
2. Jalankan seluruh
   `supabase/diagnostics/g6_phase7b_finance_uat_seed_preflight.sql`.
3. Jangan lanjut bila ada `BLOCKER`.
4. Jalankan seluruh
   `supabase/operations/g6_phase7b_create_finance_uat_dataset.sql`.
5. Export hasil akhir operation sebagai bukti nomor dokumen manusiawi.
6. Jalankan seluruh
   `supabase/diagnostics/g6_phase7b_finance_uat_seed_postflight.sql`.
7. Seluruh baris postflight harus `PASS`.

Operation dibungkus satu transaction. Error di Product, Opening Stock, queue,
jurnal, atau Adjustment akan me-rollback seluruh dataset.

## Uji Backoffice Finance

Gunakan periode bulan saat script dijalankan:

1. `Finance > Journal Entries`: cari jurnal Opening Stock Rp5.000.000; expand
   dan pastikan total debit sama dengan credit.
2. `Finance > Buku Besar`: expand akun Inventory dan Opening Balance Clearing;
   kedua sisi jurnal harus terlihat dengan nilai berlawanan.
3. `Finance > Laporan`: Trial Balance tetap seimbang; Neraca memasukkan jurnal
   Opening Stock yang sudah POSTED.
4. `Finance > Posting Queue`: run UAT tampil `COMPLETED`, satu item POSTED.
5. `Finance > Pending Analysis`: Stock Gain Rp250.000 tampil sebagai belum
   masuk laporan keuangan.
6. Export XLSX Buku Besar dan Journal Entries bulan berjalan; buka file dan
   verifikasi jurnal UAT tersedia.

## Compatibility dan Batas

- Tidak mengubah schema, grant, RLS, migration ledger, atau feature entitlement.
- Tidak membuat Sale, Purchase, Expense, Deposit, AP, AR, Customer Balance,
  Asset, atau event Finance deferred lainnya.
- Tidak menyediakan cleanup destructive. Untuk mengulang dataset, gunakan
  database UAT baru atau Company pilot baru setelah provisioning resmi.
- Jurnal otomatis tidak boleh direversal melalui UI; koreksi harus melalui
  source document resmi. Dataset ini tidak membuat jurnal manual palsu hanya
  untuk mengetes tombol reversal.

## Forward Fix

Jika operation gagal, transaction akan rollback. Simpan pesan error dan
perbaiki readiness/master/config melalui flow resmi, lalu ulangi preflight.
Jangan mengganti error dengan direct INSERT ke Stock, FIFO, Movement, Event,
Queue, atau Finance Journal.
