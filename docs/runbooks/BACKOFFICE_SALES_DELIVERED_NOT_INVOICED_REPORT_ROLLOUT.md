# Backoffice Sales Delivered Not Invoiced — Step 5/6.3

## Historical clone rehearsal — 2026-09-15

Unit 71 installed only on `idrufihckscppsyclmsu`; six preflight and seven postflight
checks PASS. Existing test PASS covers classifier and definition markers only,
not transaction-backed report results. Persistent receipt/allocation rows zero;
these are inventory, not behavioral proof. Real-row DNI RPC and authenticated
smoke/UAT pending. Production/client untouched; installed migration unchanged.
Rehearsal stopped before next unit 72 because its test requires an existing SO
but clone has zero; canonical rollback-only fixture audit required before proceeding.


Status: `DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS ON ISOLATED
DEVELOPMENT; AUTHENTICATED SMOKE/UAT PENDING`.

Target database hanya isolated Development `fkywtxucmyjvpwdiqpix`. Jangan
menjalankan paket ini pada production atau staging.

## Kontrak yang dikunci

- Mengikuti model Odoo: posisi kumulatif per baris SO, bukan alokasi Invoice ke
  batch penerimaan secara FIFO.
- Basis report adalah quantity yang diterima Customer sampai tanggal `As of`
  dikurangi quantity pada Invoice `POSTED` sampai tanggal tersebut.
- Draft Invoice tetap masuk Delivered Not Invoiced dan ditandai `Sudah masuk
  Draft Invoice` atau `Sebagian masuk Draft Invoice`.
- Begitu Invoice menjadi `POSTED`, quantity terkait keluar dari report tanpa
  menunggu pembayaran.
- Regular SO dan accepted overage merupakan source terpisah. Migration `137000`
  wajib sudah PASS agar overage tidak dihitung dua kali.
- Ongkir SO yang belum masuk Invoice Posted ikut sebagai komponen nilai
  `DELIVERY_FEE`; ongkir Draft tetap termasuk sesuai policy Invoice existing.
- Nilai adalah estimasi commercial source SO/approved overage, bukan Journal
  dan bukan financial statement.

## Impact map

Direct impact:

- satu RPC report read-only `get_finance_delivered_not_invoiced`;
- satu classifier private untuk status Draft/Posted;
- tab Laporan Finance, API report, export XLSX, dan katalog Data Exchange.

Tidak berubah:

- Stock, Reservation, Transit, FIFO, DO/SJ dan Customer Receipt;
- Draft/Posting/Cancel Invoice, allocation counter, Payment dan AR;
- Financial Event, Posting Queue, Journal dan Accounting Period;
- POS/Retail flow, Return, Purchase, tenant data, dan role assignment.

Compatibility dan risiko:

- data lama tidak dibackfill atau diubah;
- report membaca reminders historis dari `accepted_date` dan `posted_at`;
- Draft hanya memengaruhi label/quantity Draft dan tetap termasuk outstanding;
- `As of` masa depan ditolak;
- report tenant-scoped dan membutuhkan role Finance serta capability
  `finance.journals_reports.VIEW`; export juga memakai capability `EXPORT`.

## Urutan manual

Jalankan seluruh isi file, bukan selected text:

1. [Preflight](../../supabase/diagnostics/backoffice_sales_delivered_not_invoiced_report_preflight.sql)
2. [Migration](../../supabase/migrations/20260912138000_backoffice_sales_delivered_not_invoiced_report.sql)
3. [Behavioral test](../../supabase/tests/backoffice_sales_delivered_not_invoiced_report_behavior.sql)
4. [Postflight](../../supabase/diagnostics/backoffice_sales_delivered_not_invoiced_report_postflight.sql)

Preflight tidak boleh mempunyai `BLOCKER`. Behavioral dan postflight harus
seluruhnya `PASS`.

## Authenticated smoke setelah SQL PASS

1. Jalankan Backoffice lokal melalui environment guard Development.
2. Login sebagai user Finance pada Company fixture.
3. Buka Finance → Laporan → `Delivered Not Invoiced`.
4. Pastikan baris Customer Receipt tanpa Invoice tampil `Belum dibuat Invoice`.
5. Buat Draft Invoice: baris tetap tampil dan label berubah menjadi Draft.
6. Post Invoice: quantity Posted keluar dari report; partial Posted menyisakan
   selisihnya.
7. Pastikan accepted overage tampil satu kali sebagai source overage.
8. Export XLSX dan cocokkan total dengan tampilan.
9. Uji user tanpa akses Finance dan user Company lain ditolak.

## Forward-fix / rollback

Migration hanya menambah function dan ledger. Sebelum dipakai user, rollback
dapat dilakukan dengan menghapus public/private function dan ledger `138000`
dalam transaksi. Setelah dipakai, gunakan migration forward-fix; jangan edit
migration applied. UI client hanya boleh dirilis setelah database gate PASS.
