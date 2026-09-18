# Sales Invoice Source Order Link

**Status:** CLIENT LOCAL READY  
**Tanggal:** 2026-09-18

## Outcome

Daftar dan detail Invoice Penjualan menyediakan navigasi ke dokumen order
sumber tanpa mengubah transaksi:

- Invoice Backoffice membuka Sales Order asal memakai `salesOrderId` dan
  menampilkan nomor SO canonical.
- Invoice Retail/ONLINE membuka histori order Retail memakai `salesId`. Label
  tidak mengarang nomor SO karena read model Invoice Retail tidak menyediakan
  nomor tersebut; nomor dokumen asli ditampilkan oleh histori sumber.
- Link membawa `companyId` dan halaman tujuan menolak hasil dari Company lain.

## Impact boundary

- Direct: UI Invoice Penjualan, router view Backoffice, dan pembukaan histori
  Retail existing.
- Tidak berubah: schema/database, Invoice/SO/Retur status, Stock/FIFO,
  reservation, payment, Journal, permission, cancel policy, atau data lama.
- Tidak ada migration atau backfill.

## Verification

- Scoped ESLint: PASS.
- TypeScript `tsc --noEmit`: PASS.
- `next build`: PASS, 87 static pages.
- Authenticated visual smoke masih manual.

## Manual smoke

1. Buka **Sales > Invoice Penjualan** pada Company aktif.
2. Pada Invoice Retail/ONLINE, klik **Buka order sumber Retail** dari daftar dan
   dari detail. Pastikan histori order dengan Company yang sama terbuka.
3. Pada Invoice Backoffice, klik nomor **SO** dari daftar atau **Buka SO** dari
   detail. Pastikan SO yang tepat terbuka.
4. Kembali ke Invoice dan pastikan print/download/status tetap sama.

Rollback client: revert empat file UI/router yang tercantum pada handoff. Tidak
ada rollback database.
