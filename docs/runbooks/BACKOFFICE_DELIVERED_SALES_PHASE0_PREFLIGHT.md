# Backoffice Delivered-Quantity Sales — Phase 0 Preflight

**Status:** LOCAL READY / DATABASE NOT RUN / NO RUNTIME CHANGE

Audit source menemukan tiga incompatibility struktural:

1. `sales_invoice_snapshots` unik pada `(company_id,sales_id)`, sehingga satu SO
   belum dapat mempunyai beberapa Invoice;
2. `sales_delivery_documents` unik pada `(company_id,sales_id)`, sehingga satu
   SO belum dapat mempunyai beberapa DO/Backorder;
3. `sales_delivery_documents.invoice_snapshot_id` masih `NOT NULL`, sehingga DO
   belum dapat mendahului Invoice.

`sales_headers.session_id` juga masih wajib dan source existing dirancang untuk
POS. Backoffice tidak boleh menyiasatinya dengan Cashier Session palsu.

## Artifact dan cara menjalankan

Jalankan manual seluruh isi
`supabase/diagnostics/backoffice_delivered_sales_phase0_preflight.sql` di SQL
Editor bila audit database diperlukan. SQL hanya membaca catalog/runtime dan
tidak mengubah data.

- `BLOCKER`: state aktif/dependency hilang; migration tidak boleh lanjut.
- `SETUP`: capability target belum ada; expected di Phase 0, bukan bukti siap.
- `REVIEW`: desain lineage harus dibuktikan sebelum migration.
- `PASS`: dependency ada; row nol bukan bukti behavioral.

## Impact map foundation berikutnya

Direct impact hanya catalog feature default OFF, immutable process/source, dan
model identitas dokumen Backoffice. Foundation belum boleh mengubah POS
`confirm_pos_sales_order`, Reservation/Dispatch/FIFO/Movement, Payment/Finance,
Invoice/SJ historis, Sales Return, atau client.

Risiko utama adalah melepas constraint current terlalu awal. Foundation harus
additive dan terisolasi lebih dulu. Status belum `LOCAL DATABASE PASS`, belum
`CLIENT LOCAL SMOKE PASS`, dan belum `UAT PASS`.
