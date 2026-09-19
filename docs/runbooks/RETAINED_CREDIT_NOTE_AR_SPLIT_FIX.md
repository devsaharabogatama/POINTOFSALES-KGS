# Retained Retail Credit Note AR Split Fix

Status: LOCAL READY. Production database execution and authenticated smoke are manual.

## Root cause

Retained Retail Credit Note posting used legacy `sales_headers.sisa_piutang` to split Credit Note value between Customer Receivable and Refund Liability. Converted delivered Retail orders use dispatch-effective receivable instead. This caused `CN-20260919-0000000012` for source Invoice `INV-20260904-0000000236` to record AR reduction zero and Refund Liability Rp78.400 while Customer Receipt still held Rp5.428.520 outstanding. The exact target is keyed by Credit Note plus source Invoice, not by an assumed Company name.

## Run order

1. Run `supabase/diagnostics/retained_credit_note_ar_split_fix_preflight.sql` fully; every gate must PASS.
2. Run `supabase/migrations/20260919131000_retained_credit_note_ar_split_fix.sql` fully.
3. Run `supabase/tests/retained_retail_credit_note_refund_bridge_behavior.sql` fully; it must PASS and rolls back its fixtures. The test now creates its own Return, approval, physical receipt, allocation, partial payment, Credit Note, Refund, and Refund reversal inside the rollback-only transaction. It no longer consumes or depends on a pre-existing unallocated Return. This re-proves partial payment, AR-first split, real Refund, and Refund reversal under the corrected runtime.
4. Run `supabase/tests/retained_credit_note_ar_split_fix_behavior.sql` fully; it must PASS and rolls back its context write.
5. Run `supabase/diagnostics/retained_credit_note_ar_split_fix_postflight.sql` fully; every row must PASS.
6. Reload Penerimaan Customer for Tukino. Invoice `INV-20260904-0000000236` must show initial Rp5.428.520, Return reduction Rp78.400, remaining Rp5.350.120.

## Accounting effect

The erroneous posted Refund is preserved and reversed with a linked immutable Refund Reversal plus exact reversal Journal. The original posted Credit Note Journal also remains immutable. One append-only correction Journal then debits Customer Refund Liability and credits Customer Receivable Rp78.400. The Credit Note split is reconciled to AR Rp78.400 / Refund Rp0. Stock, FIFO, Retail source Invoice, Customer Receipt history, and original Journals are not rewritten.

## Forward-fix

Future retained Retail Credit Notes use dispatch-effective receivable at the Credit Note date. If any gate fails, do not delete data or bypass the guard; retain the output and issue a new forward-fix.
