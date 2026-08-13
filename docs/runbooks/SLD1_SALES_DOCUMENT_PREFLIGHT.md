# SLD-1 Sales Document Preflight

## Outcome

Menjalankan audit read-only sebelum schema Sales Invoice formal dan Surat Jalan
dibuka. Preflight ini tidak membuat dokumen, tidak mengubah Sale, dan tidak
menjalankan function bisnis.

Source of truth kontrak:
[`../SALES_INVOICE_DELIVERY_DOCUMENT_SPEC.md`](../SALES_INVOICE_DELIVERY_DOCUMENT_SPEC.md).

## File

`supabase/diagnostics/sld_phase1_sales_document_preflight.sql`

## Cara Menjalankan

1. Buka Supabase SQL Editor pada project yang sama dengan Backoffice/PWA.
2. Salin **seluruh** isi file preflight.
3. Pastikan query pertama diawali komentar `SLD phase 1 preflight` dan statement
   eksekusinya dimulai `WITH required_versions`.
4. Jalankan sekali lalu export/copy seluruh hasil `check_name,status,details`.
5. Kirim seluruh output, bukan hanya row yang gagal.

Jangan menjalankan potongan Markdown atau teks penjelasan sebagai SQL.

## Interpretasi

- `BLOCKER`: harus nol sebelum SLD-2. Jangan membuat/jalankan migration dokumen.
- `REVIEW`: data master masih boleh dipakai untuk Pickup, tetapi field delivery
  perlu dilengkapi atau penerima wajib diisi manual.
- `BACKFILL`: expected untuk Sale POSTED existing; SLD-2 akan menangkap
  immutable legacy-cutover snapshot secara eksplisit.
- `SETUP`: expected karena schema/runtime canonical memang belum dibuat.
- `PASS`: invariant existing aman.
- `INFO`: inventory/privilege, bukan approval otomatis.

Expected pada baseline sebelum SLD-2:

- `canonical_sales_document_schema_state = SETUP`;
- `company_branding_document_retention_contract = SETUP`;
- `formal_invoice_snapshot_backfill_scope = BACKFILL` bila sudah ada Sale
  POSTED;
- Customer/Store tanpa phone/address dapat muncul `REVIEW`;
- seluruh `BLOCKER` harus `PASS`/nol.

## Keputusan Setelah Output

Jika `BLOCKER` nol:

1. SLD-1 ditutup;
2. SLD-2 membuat migration additive untuk snapshot Invoice, fulfillment intent,
   Surat Jalan, counter/audit, RLS/RPC, dan logo retention;
3. lanjut postflight, rollback-safe behavior, retry/concurrency, cross-tenant,
   Return/no-double-effect regression;
4. baru sesudah database gate PASS masuk ke SLD-3 UI/print.

Jika ada `BLOCKER`, perbaikan dilakukan sebagai forward-fix paling sempit.
Jangan mengubah historical total, Payment, Stock Movement, atau Financial Event
untuk sekadar membuat dokumen dapat dicetak.

## Rollback

Tidak ada rollback database: file ini SELECT-only. Hapus/abaikan hasil query jika
menjalankan terhadap environment yang salah, lalu ulangi pada project benar.
