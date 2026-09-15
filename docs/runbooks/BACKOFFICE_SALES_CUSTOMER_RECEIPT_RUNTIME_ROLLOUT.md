# Backoffice Sales Customer Receipt Runtime Rollout

Status: `DATABASE LIVE ON ISOLATED DEVELOPMENT; MANUAL POSTFLIGHT/BEHAVIOR PASS`

Target: Supabase isolated Development `fkywtxucmyjvpwdiqpix` only.

## Outcome

DO Backoffice yang sudah `IN_TRANSIT` dan terkirim penuh dapat dikonfirmasi
diterima. Tanggal otomatis mengikuti tanggal Company, tetapi operator dapat
mengubahnya. Runtime mengurangi stok dan FIFO hanya dari batch Transit yang
dibuat Dispatch DO tersebut, menyelesaikan DO/Reservation/SO, menambah Accepted
dan Qty To Invoice, lalu membuat Financial Event COGS berstatus `HOLD`.

Tidak dibuat pada gate ini: Invoice, Revenue, Tax, AR, Payment, Journal sinkron,
partial receipt, discrepancy, Return, atau Backorder baru. Flow POS tidak berubah.

## Urutan manual

Jalankan satu file penuh per langkah melalui SQL Editor project Development:

1. `supabase/diagnostics/backoffice_sales_customer_receipt_runtime_preflight.sql`
2. Pastikan tidak ada `BLOCKER`.
3. `supabase/migrations/20260909154000_backoffice_sales_customer_receipt_runtime.sql`
4. `supabase/diagnostics/backoffice_sales_customer_receipt_runtime_postflight.sql`
5. Pastikan seluruh pemeriksaan non-`INFO` bernilai `PASS`.
6. `supabase/tests/backoffice_sales_customer_receipt_runtime_behavior.sql`
7. Jalankan postflight sekali lagi.
8. Restart Backoffice lokal, hard refresh, lalu smoke melalui Inventory > Surat Jalan.

Jangan gunakan `supabase db push`: migration sebelumnya dipasang manual sehingga
ledger CLI tidak sama dengan ledger aplikasi. Jangan jalankan pada production
atau staging lama.

## Authenticated smoke

1. Buat Quotation, Confirm menjadi SO dan DO.
2. Dispatch seluruh qty sampai status `Dalam perjalanan`.
3. Klik `Konfirmasi diterima`.
4. Pastikan tanggal terisi tanggal Company dan dapat diedit.
5. Konfirmasi; DO/SO menjadi `Selesai`, Qty To Invoice bertambah, Transit berkurang.
6. Retry tidak boleh membuat receipt, Movement, FIFO allocation, atau Event ganda.
7. Tanggal besok dan tanggal sebelum Dispatch wajib ditolak.
8. Pastikan POS retail, Surat Jalan POS, Payment, Invoice, dan Journal existing tetap sama.

## Forward-fix / rollback

Migration menambah enum `BACKOFFICE_SALE`; nilai enum dapat tetap ada bila bagian
transactional migration gagal. Jangan menghapus enum pada database aktif.
Sebelum ada receipt nyata, fungsi dapat di-drop dan reader dikembalikan ke versi
2. Setelah ada receipt nyata, gunakan forward-fix; jangan menghapus receipt,
FIFO allocation, Stock Movement, atau Event immutable.

Finance Journal untuk Event `BACKOFFICE_CUSTOMER_RECEIPT` masih gate berikutnya.
Event sengaja `HOLD`, sehingga kegagalan Finance tidak membatalkan penerimaan.
