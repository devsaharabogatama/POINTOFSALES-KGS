# Backoffice Sales Return & Refund Step 5/5 Rollout

Status: `LOCAL READY`; database rollout, authenticated smoke, dan UAT belum dilakukan.

## Dampak

- Sales memperoleh workspace Retur & Refund, link dari SO, Credit Note, refund,
  reversal, dan log aktivitas.
- Inventory memperoleh Penerimaan Retur Customer dengan authority
  `inventory.customer_return_receipts`; Gudang tidak diwajibkan punya izin Sales.
- Mutation tetap memakai RPC Step 1-4. Migration Step 5 hanya menambah tiga
  read-model tanpa backfill atau mutation Stock, FIFO, Invoice, Payment,
  Financial Event, Journal, Retur Retail, POS, atau Cashier Session.

## Urutan manual

Jalankan setiap file penuh pada database yang sudah memiliki Step 1-4 sampai
`20260917151000`:

1. [Preflight](../../supabase/diagnostics/backoffice_sales_return_ui_preflight.sql)
2. [Migration](../../supabase/migrations/20260918100000_backoffice_sales_return_ui_read_models.sql)
3. [Postflight](../../supabase/diagnostics/backoffice_sales_return_ui_postflight.sql)
4. deploy client hanya setelah semua check non-`INFO` `PASS`.

Hentikan rollout pada SQL error, `BLOCKER`, atau `FAIL`. Migration tidak boleh
dijalankan ulang setelah ledger terpasang.

## Authenticated smoke wajib

1. Sales membuat Draft Retur dari SO selesai, lalu submit.
2. Sales Admin atau Finance menyetujui; actor berbeda harus tetap boleh.
3. Gudang mem-post split RESTOCK/DESTROY; DESTROY tanpa catatan harus ditolak.
4. Finance mengalokasikan qty secara eksplisit ke un-invoiced, Draft Invoice,
   dan Posted Invoice; sistem tidak boleh menebak Invoice.
5. Post Credit Note, partial refund, exact retry, lalu source-linked reversal;
   verifikasi Journal balance dan Customer Statement.
6. Verifikasi cross-Company ditolak dan stale version ditolak.
7. Verifikasi Retur Retail, Supplier Receipt, POS, dan Cashier Session tetap.

Jika read-model gagal setelah install, gunakan migration forward-fix baru.
Jangan menghapus histori atau dokumen final Step 1-4.

## UI refinement 2026-09-18

Status client: `LOCAL READY`.

- Workspace Retur & Refund sekarang mengikuti pola visual Quotation/SO dan
  RO/PO: header modul, filter terpisah, daftar tabel, badge sumber/status,
  ringkasan dokumen, tabel barang, koreksi tagihan, Credit Note/Refund, dan
  activity log memiliki hierarki yang konsisten.
- Penerimaan Retur Customer di Inventory memakai daftar tabel dan modal
  penerimaan terstruktur. Qty tetap otomatis mengikuti sisa Retur tetapi masih
  dapat diedit; Gudang dan tindakan `RESTOCK`/`DESTROY` tetap per baris.
- Tidak ada perubahan endpoint, payload mutation, RPC, permission, Stock,
  FIFO, Invoice, Payment, Journal, atau data historis.
- Evidence lokal: targeted ESLint dua komponen `PASS`; Next.js production build
  beserta TypeScript dan 87 static pages `PASS`.
- Authenticated visual smoke belum `PASS`: browser automation agent tertahan
  oleh runtime tool (`missing sandboxPolicy`). Sesudah client di-deploy, cek
  daftar, detail, Draft Retur, penerimaan Gudang, Credit Note, Refund, serta
  viewport sempit sebelum menandai `CLIENT DEPLOYED`/`SMOKE PASS`.

## Status Invoice sumber setelah Retur

Status Invoice pada daftar/detail tidak lagi hanya membaca status dokumen asli.
Rollout additive terpisah membaca Retur dan Credit Note tanpa memutasi histori;
ikuti [runbook status komersial Invoice](SALES_INVOICE_RETURN_COMMERCIAL_STATUS_ROLLOUT.md)
sebelum smoke status `Retur diproses`, `Diretur sebagian`, dan `Diretur penuh`.
