# LSM Credit Note Zero-Value Impact Audit

**Tanggal:** 2026-11-06  
**Klasifikasi:** `PRODUCT_BEHAVIOR_CHANGE` + `SCHEMA_OR_MIGRATION_CHANGE`  
**Status:** Fase A read-only selesai untuk defect presentasi Draft; belum ada
perubahan runtime/schema/data.

## Expected business outcome

Untuk Return `RTN-20261021-0000000033`, barang T27BC yang diterima kembali
sebanyak 20 PACK dari Invoice `INV-20261016-0000000717` harus membentuk Draft
Credit Note senilai Rp510.000 (20 x Rp25.500, diskon dan pajak nol). Draft tidak
boleh mem-posting Finance sampai user menekan aksi Post.

## Evidence UI Production

- Company aktif: LSM.
- SO `SO-20261015-0000000371`, Customer Sahl Mart Cibubur.
- Invoice `INV-20261016-0000000717` bernilai Rp1.350.000 dan sudah dibayar
  Rp1.350.000 melalui `CR/2026/10/000504`.
- Baris T27BC: 20 PACK x Rp25.500 = Rp510.000; diskon nol; tanpa pajak.
- Return menerima kembali 20 PACK dan menambah stok.
- Draft Credit Note `CN-20261106-0000000025` ditampilkan dengan
  `Pengurang piutang Rp0` dan `Kewajiban refund Rp0`; UI tidak menampilkan
  `grandTotal` Draft.
- Tidak ada Post Credit Note yang dijalankan selama smoke.

## Active execution path

1. `BackofficeSalesReturnView.allocate()` mengirim allocation ke
   `/api/sales/backoffice-returns/[id]/allocate`.
2. Route memanggil
   `public.allocate_backoffice_sales_return_invoices(uuid,bigint,uuid,jsonb)`.
3. Dispatcher native mengarah ke
   `private.allocate_backoffice_sales_return_invoices_before_retained(...)`.
4. Definisi aktif repository terakhir berada di migration
   `20261006140000_backoffice_unified_posted_invoice_revision.sql:1702-1983`.
5. Nilai komersial Draft berasal dari
   `private.backoffice_invoice_effective_line_amounts(...)`, diprorata pada
   baris 1941-1960, ditulis ke `backoffice_sales_credit_note_lines`, lalu header
   dihitung oleh `private.recalculate_backoffice_sales_credit_note(...)`.
6. Snapshot API sudah membawa `grandTotal`, `arReductionAmount`, dan
   `refundLiabilityAmount` (`20260917131000...sql:114-143`).
7. `BackofficeSalesReturnView.tsx` mendeklarasikan `grandTotal` tetapi daftar
   dan modal hanya merender `arReductionAmount` dan `refundLiabilityAmount`.
8. Constraint header mewajibkan kedua nilai AR/refund tetap nol saat status
   `DRAFT` (`20260917130000...sql:169-189`). Karena itu UI sedang menampilkan
   nilai hasil posting sebagai pengganti nilai komersial Draft.

## Impact map

### Root cause terbukti

Ini adalah **PRODUCT FIX pada presentasi UI**: `grandTotal` tersedia dalam
payload tetapi tidak dirender. Angka Rp0 yang terlihat bukan bukti nilai barang
Return nol; angka itu adalah field posting yang secara kontrak memang nol selama
Draft. Pernyataan sebelumnya bahwa database Draft pasti bernilai Rp0 dicabut.

### Direct impact

- daftar Credit Note pada workspace Return;
- ringkasan modal Credit Note Draft dan Posted;
- tidak ada perubahan calculation, mutation, schema atau Finance.

### Downstream impact

- Post Credit Note, Finance Event/Journal dan AR open credit Task 4;
- Invoice commercial status/net presentation;
- Customer Receipt/outstanding, AR Aging, schedule dan Customer Statement;
- refund/manual allocation pada fase berikutnya.

### Explicitly preserved

- Retained Retail dan seluruh POS Retail;
- penerimaan fisik Return, Stock/FIFO/HPP yang sudah Posted;
- Invoice/Receipt/Journal historis;
- Draft Invoice adjustment dan `UNINVOICED` branch;
- multi-Company, permission, retry, version dan audit.

## State classification

- Task 4 migration `20261105120000`: `INSTALLED_CONSISTENT` berdasarkan ledger,
  postflight, tiga rollback behavior dan closing postflight yang diberikan user.
- Exact Draft Credit Note: ada di Production berdasarkan UI, tetapi detail row
  dan hasil helper database belum dibaca.
- Diagnosis fix: `UNKNOWN` sampai SELECT-only exact diagnostic dijalankan.

## Unknown yang tidak mengubah desain UI

Nilai exact `grandTotal` Production tetap perlu dibaca untuk menutup smoke data,
tetapi tidak mengubah desain UI: nilai komersial harus selalu ditampilkan dari
`grandTotal`, sedangkan AR/refund harus diberi konteks bahwa keduanya baru
ditentukan saat posting. Diagnostic exact tetap dipertahankan sebagai bukti
data dan Finance boundary, bukan sebagai prasyarat desain presentasi.

## Regression matrix untuk calon fix

- native Backoffice: Posted Invoice unpaid/partial/full paid;
- full dan partial quantity Return; diskon/pajak nol dan nonnol;
- price revision ada/tidak ada;
- Draft Invoice dan UNINVOICED tetap sama;
- Retained Retail/POS tetap sama;
- same/cross Company, stale version, exact retry dan changed retry;
- Stock/FIFO tidak berubah saat memperbaiki nilai komersial;
- Draft tidak membuat Finance Event/Journal/open credit;
- Post baru tetap satu balanced Journal dan satu AR open credit;
- data Draft Rp0 existing memiliki forward-fix yang eksplisit dan diaudit.

## Planned Fase B

1. Tambahkan `Nilai Credit Note` dari `note.grandTotal` pada daftar dan modal.
2. Label nilai AR/refund sebagai hasil posting, bukan nilai Draft.
3. Tambahkan kontrak test yang memastikan `grandTotal` dirender dan tidak
   digantikan field posting.
4. Lint, TypeScript, build, lalu authenticated UI smoke tanpa menekan Post.
5. Jalankan diagnostic exact untuk memastikan nilai Production Rp510.000 dan
   zero Finance Event/Journal. Bila data ternyata berbeda, bekukan patch UI dan
   buka audit runtime/data terpisah.

## Fase B local evidence

- Implementasi hanya pada presentasi
  `backoffice/src/components/BackofficeSalesReturnView.tsx`.
- Daftar dan modal menggunakan `note.grandTotal` sebagai `Nilai Credit Note`.
- Untuk status `DRAFT`, `arReductionAmount` dan `refundLiabilityAmount` tidak
  lagi ditampilkan sebagai Rp0 yang menyesatkan, tetapi `Belum diposting`.
- Kontrak terfokus
  `backoffice/tests/backoffice-sales-return-credit-note-ui.test.mjs`: `3/3 PASS`.
- Scoped ESLint: PASS.
- TypeScript `--noEmit`: PASS.
- Next.js production build: PASS.
- Authenticated local read-only smoke: PASS pada LSM Return
  `RTN-20261021-0000000033` dan Draft `CN-20261106-0000000025`. Daftar dan
  modal menampilkan Rp510.000 serta seluruh dampak posting sebagai
  `Belum diposting`. Modal ditutup tanpa Save/Post dan dokumen tetap Draft.
- Exact Production Finance-boundary diagnostic: BELUM DIJALANKAN.
- Status: `AUDIT COMPLETE: YES`; `LOCAL READY: YES`; `DATABASE LIVE: N/A
  (tidak berubah)`; `CLIENT DEPLOYED: NO`; `LOCAL SMOKE PASS: YES`;
  `PRODUCTION SMOKE PASS: NO`; `UAT PASS: NO`.
