# KGS POS Backoffice

Backoffice Next.js untuk master data, Inventory, Sales, Finance, dan pengaturan
Company. Database disbursement Phase-34 sudah dikonfirmasi PASS. G4 Phase-35
menambahkan `Finance > Approval Expense` untuk mengonfirmasi pembayaran
Transfer/non-tunai dengan nominal/metode dari dokumen approved. Expense Cash
tetap dicairkan melalui POS Session. Phase 38 juga menampilkan request biaya
aktual untuk approve/reject dan membuka pengembalian dana non-tunai melalui
RPC guarded. Pengembalian Cash tetap hanya di POS agar masuk ke Session/laci
yang benar. Phase 41 menambahkan review request dana tambahan dan pembayaran
non-Cash dengan nominal/metode approved yang read-only; dana tambahan Cash
tetap hanya dicairkan dari POS. Jurnal final tetap tertutup.

Phase 47 menambahkan `Finance > Selisih Setoran`: list/detail tenant-scoped,
penanggung jawab setoran kurang, partial resolution, serta maker-checker untuk
biaya/pendapatan/write-off/koreksi source. Seluruh write memakai guarded RPC;
Accounting read-only. Bank matching, reversal source aktual, dan jurnal G6
belum dibuka. Panduan smoke ada di
[`../docs/runbooks/G4_PHASE47_DEPOSIT_VARIANCE_OPERATIONAL_UI.md`](../docs/runbooks/G4_PHASE47_DEPOSIT_VARIANCE_OPERATIONAL_UI.md).

Source of truth dan status rollout berada di [`../README.md`](../README.md) dan
[`../docs/ACTIVE_DEVELOPMENT_HANDOFF.md`](../docs/ACTIVE_DEVELOPMENT_HANDOFF.md).

G5 Phase 9 menambahkan `Purchase > Retur Pembelian`: Manager/Admin mereview
Draft dari POS, menyetujui tanpa alasan, menolak/membatalkan dengan alasan, lalu
memposting secara terpisah. Posting mengurangi FIFO/stok asal dan mencatat AP
adjustment melalui RPC guarded; Supplier Invoice dan jurnal final tetap belum
dibuka. Smoke checklist ada di
[`../docs/runbooks/G5_PHASE9_PURCHASE_RETURN_OPERATIONAL_UI.md`](../docs/runbooks/G5_PHASE9_PURCHASE_RETURN_OPERATIONAL_UI.md).

Phase 61 menambahkan konfigurasi `Pengaturan Modul > Point of Sale > Izin Stok
Minus POS`. Super Admin mengelola entitlement; Company Owner/Admin mengelola
policy, opt-in Gudang penjualan, dan izin user melalui guarded RPC. Store
Manager read-only. Smoke checklist ada di
[`../docs/runbooks/G4_PHASE61_NEGATIVE_STOCK_OPERATIONAL_UI.md`](../docs/runbooks/G4_PHASE61_NEGATIVE_STOCK_OPERATIONAL_UI.md).

## Getting Started

First, run the development server:

```bash
npm run dev
# or
yarn dev
# or
pnpm dev
# or
bun dev
```

Open [http://localhost:3000](http://localhost:3000) with your browser to see the result.

You can start editing the page by modifying `app/page.tsx`. The page auto-updates as you edit the file.

This project uses [`next/font`](https://nextjs.org/docs/app/building-your-application/optimizing/fonts) to automatically optimize and load [Geist](https://vercel.com/font), a new font family for Vercel.

## Learn More

To learn more about Next.js, take a look at the following resources:

- [Next.js Documentation](https://nextjs.org/docs) - learn about Next.js features and API.
- [Learn Next.js](https://nextjs.org/learn) - an interactive Next.js tutorial.

You can check out [the Next.js GitHub repository](https://github.com/vercel/next.js) - your feedback and contributions are welcome!

## Deploy on Vercel

The easiest way to deploy your Next.js app is to use the [Vercel Platform](https://vercel.com/new?utm_medium=default-template&filter=next.js&utm_source=create-next-app&utm_campaign=create-next-app-readme) from the creators of Next.js.

Check out our [Next.js deployment documentation](https://nextjs.org/docs/app/building-your-application/deploying) for more details.
