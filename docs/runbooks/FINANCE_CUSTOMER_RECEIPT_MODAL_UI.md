# Finance Customer Receipt Modal UI

Status: `CLIENT LOCAL READY`  
Tanggal: 2026-09-18

## Outcome

Tombol **Penerimaan baru** pada Finance > Penerimaan Customer membuka form
dalam modal. Edit Draft memakai modal yang sama. Form tidak lagi muncul jauh di
bawah laporan sehingga aksi tombol langsung terlihat oleh user.

Modal dapat ditutup melalui tombol silang, klik backdrop, atau `Escape` selama
request penyimpanan tidak berjalan. Error validasi juga tampil di dalam modal.

## Sumber metode pembayaran

Metode pembayaran bukan hardcode UI. Jalur aktifnya:

1. `CustomerReceiptView` memanggil `GET /api/finance/customer-receipts`;
2. route memanggil RPC `get_finance_customer_receipts()`;
3. RPC membaca master `public.payment_methods` milik Company aktif;
4. hanya master aktif dengan `settlement_route` `CASH_DRAWER` atau
   `DIRECT_BANK` yang dikirim ke form.

Label `Kas` dan `Bank` di client hanya terjemahan jalur settlement. Nama metode,
ID, tipe, status aktif, dan konfigurasi accounting tetap berasal dari master
Payment Method.

## Impact dan compatibility

- Perubahan hanya pada presentasi `CustomerReceiptView`.
- API, RPC, permission, allocation, optimistic version, posting Journal,
  Customer Balance, audit, dan transaksi existing tidak berubah.
- Tidak ada migration, backfill, atau langkah SQL.
- Rollback client: kembalikan perubahan komponen; data tidak perlu dipulihkan.

## Verification

- `npx.cmd eslint src/components/CustomerReceiptView.tsx`
- `npx.cmd tsc --noEmit`
- `npm.cmd run build`

Authenticated visual smoke tetap manual: buka Finance > Penerimaan Customer,
klik **Penerimaan baru**, uji validasi, simpan Draft, lalu buka kembali melalui
aksi **Edit**.
