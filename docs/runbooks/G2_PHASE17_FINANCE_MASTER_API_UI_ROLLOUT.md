# G2 Phase 17 — Finance Master API/UI Rollout

## Tujuan

Membuka Backoffice untuk mengelola nama Kategori Transaksi dan mapping
effective-dated ke akun Company melalui RPC yang sudah dijaga pada phase 16.
Chart of Accounts ditampilkan read-only. Fase ini tidak menjalankan Finance
worker, tidak melakukan automatic posting, dan tidak membuat jurnal.

## Prasyarat

- migration `20260722150000_g2_phase16_finance_master_foundation.sql` sudah
  applied;
- postflight phase 16 menghasilkan 14 baris `PASS`;
- behavioral test phase 16 menghasilkan notice `TEST PASSED`;
- compatibility smoke menu existing tidak menampilkan error.

## Surface yang Dibuka

- menu `Kategori & COA`;
- tab `Kategori transaksi`: create/edit guarded dan optimistic version check;
- tab `Mapping akun`: membuat versi mapping baru; versi aktif sebelumnya
  ditutup oleh RPC tanpa mengubah histori;
- tab `Daftar akun`: read-only minimum Company COA;
- Escape menutup modal;
- UUID, system key, dan account-function key tidak ditampilkan sebagai label
  utama. Nama bisnis selalu menjadi label user-facing.

## Boundary yang Tetap Ditutup

- direct browser write ke Finance master tables;
- edit struktur COA dan Company account fallback;
- automatic journal resolver/worker;
- accounting period, reconciliation, reversal, dan Finance reporting.

## Local Verification

Jalankan dari folder `backoffice`:

```powershell
npm.cmd run lint
npm.cmd run build
```

Expected: kedua command selesai dengan exit code `0` dan route berikut masuk
production build:

```text
/api/master/finance-masters
/api/master/finance-masters/[id]
```

## Manual Smoke Test

1. Restart Backoffice dan pilih Company aktif.
2. Buka menu `Kategori & COA`; pastikan tidak ada notification error.
3. Buka `Daftar akun`; pastikan akun tampil memakai nama dan kode akun bisnis,
   bukan UUID.
4. Tambahkan kategori, misalnya nama `Listrik`, kode internal `LISTRIK`, lalu
   pilih jenis transaksi berdasarkan nama.
5. Edit keterangan kategori dan simpan; pastikan tidak ada duplicate name/code.
6. Pada `Mapping akun`, pilih kategori, nama fungsi akun, dan nama akun tujuan.
7. Simpan versi aktif dan pastikan tabel menampilkan versi serta periodenya.
8. Buat versi pengganti dengan waktu mulai lebih baru; pastikan histori lama
   tetap ada dan periodenya ditutup.
9. Tekan Escape pada modal kategori dan mapping; modal harus tertutup.
10. Buka kembali menu Product, Supplier, Customer, Pricelist, dan Metode
    Pembayaran untuk compatibility smoke.

## Forward Note

Setelah smoke ini lulus, next safe step adalah guarded COA/fallback management.
Jangan memakai direct table grant dan jangan mengaktifkan posting hanya karena
mapping sudah tersedia.
