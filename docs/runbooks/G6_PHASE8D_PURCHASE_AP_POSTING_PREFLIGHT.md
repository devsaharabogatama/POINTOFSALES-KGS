# G6 Phase 8D — Purchase/AP Posting Preflight

**Status:** SELECT-only ready  
**Mutation:** tidak ada

Jalankan seluruh
`supabase/diagnostics/g6_phase8d_purchase_ap_posting_preflight.sql`, lalu kirim
semua row `check_name,status,details`.

## Gate

- `BLOCKER` wajib nol.
- `purchase_ap_posting_runtime=SETUP` adalah expected sampai migration runtime
  dibuat; itu bukan kegagalan data.
- Jangan memproses HOLD Purchase/AP sebelum output ini direview.

## Yang diverifikasi

1. Goods Receipt tepat mencocokkan header, line, FIFO batch valuation, Event,
   Inventory debit, dan AP Provisional credit.
2. Supplier Invoice tepat mencocokkan allocation provisional/actual, signed
   purchase-price variance, recoverable/nonrecoverable tax, grand total, dan
   AP Final.
3. Supplier Payment tepat mencocokkan allocation invoice dan total Event.
4. Seluruh immutable account ID berasal dari Company yang sama serta masih
   aktif dan postable.
5. Belum ada journal effect parsial untuk Event target.

Preflight ini tidak memproses queue, tidak mengubah Event, tidak membuat
jurnal, dan tidak mengubah dokumen Purchase/AP.
