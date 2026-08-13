# G6 Phase 8C — Controlled Sale/Return Queue

## Install dan test rollback

1. `supabase/migrations/20260814130000_g6_phase8c_sale_return_controlled_queue.sql`
2. `supabase/diagnostics/g6_phase8c_sale_return_controlled_queue_postflight.sql`
3. `supabase/tests/g6_phase8c_sale_return_controlled_queue_tests.sql`

Expected postflight `PASS/INFO`; behavioral `TEST PASSED` lalu rollback.
Migration dan behavioral tidak meninggalkan historical Journal.

## Controlled live operation — jangan jalankan sebelum behavioral PASS

Karena behavioral sudah dikonfirmasi user PASS, operasi live tersedia sebagai:

1. `supabase/operations/g6_phase8c_post_live_sale_return.sql`
2. `supabase/diagnostics/g6_phase8c_sale_return_live_reconciliation_postflight.sql`

Login sebagai Finance/Company Admin pada Company sumber 14 HOLD, lalu jalankan
RPC berurutan dari UI/SQL authenticated context:

1. `preview_sale_return_posting_queue(100)`; catat `queueRunId`, `eventCount`,
   `previewHash`, `masterVersion`.
2. Verifikasi `eventCount` sesuai HOLD Company tersebut.
3. `approve_financial_event_posting_queue(queueRunId, masterVersion)`; gunakan
   `masterVersion` response untuk langkah berikutnya.
4. `process_financial_event_posting_queue(queueRunId, masterVersion)`.

Wajib `COMPLETED`, `failedCount=0`, `skippedCount=0`. Jika tidak, hentikan dan
kirim response lengkap; jangan mengubah Event/Journal/queue secara langsung.
