# Backoffice Sales Customer Receipt Finance Posting Rollout

Status: **DATABASE LIVE ON ISOLATED DEVELOPMENT; POSTFLIGHT/BEHAVIOR PASS**

Target: isolated Development `fkywtxucmyjvpwdiqpix` only.

## Outcome

Event `BACKOFFICE_CUSTOMER_RECEIPT` yang dibuat receipt runtime dapat diproses
oleh controlled/automatic Finance canonical menjadi jurnal:

- Debit `COGS` sebesar actual FIFO cost dari Transit;
- Credit `INVENTORY_ASSET` sebesar nilai yang sama;
- `original_event_date` = tanggal Customer menerima barang;
- `accounting_date` = tanggal penerimaan bila periodenya terbuka, atau hari
  pertama periode terbuka berikutnya sebagai `PRIOR_PERIOD_ADJUSTMENT`.

Biaya nol tidak membuat jurnal nol. Setelah seluruh source direkonsiliasi,
Event ditutup sebagai `CANCELED / NO_FINANCIAL_EFFECT`, mengikuti kontrak
Finance Goods Receipt existing.

## Boundary

Gate ini tidak mengubah receipt, Stock, FIFO, Reservation, DO, SO, Qty To
Invoice, Invoice, Revenue, Tax, AR, Payment, POS retail, atau tanggal jatuh
tempo. Posting idempotent memakai satu Event dan satu Journal; stale version,
source mismatch, tenant mismatch, period tanpa tujuan, dan account mapping
ambigu semuanya fail-closed.

## Impact map

- Direct: `private.post_financial_event_core`, predicate queue
  `private.f4b_financial_event_supported`, Event receipt, Finance Journal/lines.
- Downstream: Buku Besar dan laporan Finance membaca Journal `POSTED` canonical.
- Compatibility: dispatcher dan predicate lama disimpan sebagai wrapper
  predecessor; seluruh Event selain `BACKOFFICE_CUSTOMER_RECEIPT` diteruskan
  tanpa perubahan.
- Concurrency/retry: Event dikunci `FOR UPDATE`; unique Event/Journal dan
  idempotency key mencegah jurnal ganda.
- Rollback: setelah ada Journal `POSTED`, jangan drop wrapper atau menghapus
  Journal. Gunakan forward-fix additive. Sebelum ada posting runtime, rollback
  kode dapat mengembalikan dispatcher/predicate predecessor.

## Urutan manual

Jalankan satu file per query di SQL Editor project Development tersebut:

1. `supabase/diagnostics/backoffice_sales_receipt_finance_posting_preflight.sql`
2. Pastikan tidak ada `BLOCKER`.
3. `supabase/migrations/20260909155000_backoffice_sales_receipt_finance_posting.sql`
4. `supabase/diagnostics/backoffice_sales_receipt_finance_posting_postflight.sql`
5. Pastikan tidak ada `FAIL`.
6. `supabase/tests/backoffice_sales_receipt_finance_posting_behavior.sql`
7. Jalankan postflight sekali lagi dan pastikan tetap tidak ada `FAIL`.

Behavior test memakai Company/Store/Warehouse/Customer/Product/UOM serta nilai
enum yang sudah ada di database, menjalankan chain canonical Quotation/SO ->
Confirm -> Dispatch -> Receipt -> Finance posting, lalu `ROLLBACK`. Test juga
membuktikan tenant denial, balanced Journal, exact retry, stale version denial,
serta tidak adanya Invoice/Payment effect.

Rerun note 2026-09-10: behavioral pertama berhenti dengan `P0002` karena test
menambahkan syarat fixture bahwa periode OPEN harus mencakup hari ini. Runtime
tidak mempunyai syarat tersebut; ia mendukung periode terbuka berikutnya.
Behavioral diperbaiki tanpa mengubah migration/runtime: kandidat kembali sama
dengan receipt test yang sudah PASS, dan bila belum ada periode postable test
membuat periode fixture sendiri di dalam transaksi yang selalu di-rollback.

## Stop condition

Berhenti dan kirim output penuh bila ada SQL error, `BLOCKER`, atau `FAIL`.
Jangan menjalankan migration berikutnya, `db push`, atau deployment. PASS dengan
runtime row nol pada postflight bukan pengganti behavior test.

## Status evidence

- Local SQL delimiter/parentheses: PASS.
- Scoped `git diff --check`: PASS.
- Database migration: PASS menurut eksekusi manual user.
- Behavioral rollback: PASS menurut eksekusi manual user setelah fixture fix.
- Authenticated controlled-queue smoke: pending sebagai gate UAT terpisah.
- Production/staging: tidak disentuh.
