# Backoffice Sales Fulfillment Foundation Rollout

## Status

`DATABASE LIVE - ISOLATED DEVELOPMENT ONLY; MANUAL CONTRACT POSTFLIGHT AND
ROLLBACK BEHAVIOR PASS PER USER; CONFIRM COMPOSITION MOVED TO MIGRATION
20260909147000; CLIENT, SMOKE, AND UAT NOT STARTED`.

Migration `20260909145000` menambahkan lineage yang terpisah dari POS retail.
Forward-fix `20260909146000` mengunci kontrak bisnis final sebelum runtime:

- satu Reservation header per Sales Order Backoffice;
- Reservation lines dengan composite Company/SO/line/warehouse identity;
- satu Sales Order dapat mempunyai beberapa Delivery Order;
- DO awal menggunakan default `INITIAL` dan `READY`;
- DO lanjutan hanya `BACKORDER` dan wajib mempunyai parent DO;
- discrepancy sebelum penerimaan tetap pada DO yang sama; sesudah penerimaan
  perubahan wajib melalui Retur;
- fulfillment audit immutable;
- seluruh relation RLS aktif dan tidak dapat dibaca/ditulis langsung oleh
  `anon` maupun `authenticated`.

Migration ini zero-backfill dan tidak mengubah Confirm SO. Belum ada
Reservation/DO yang dibuat otomatis, belum ada Inventory read-model union, dan
belum ada Stock/FIFO/Invoice/Payment/Finance effect.

## Manual gate Development

Jalankan hanya pada `fkywtxucmyjvpwdiqpix`:

1. `supabase/diagnostics/backoffice_sales_fulfillment_contract_fix_postflight.sql`
2. `supabase/tests/backoffice_sales_fulfillment_foundation_behavior.sql`

Behavioral berjalan dalam transaksi dan selalu `ROLLBACK`. Test membuat satu
SO dummy, satu Reservation, DO awal, dan DO Backorder; menguji audit immutable;
serta membandingkan jumlah Reservation retail, SJ retail, Invoice, Stock
Movement, dan Financial Event sebelum/sesudah.

Hentikan bila SQL error atau ada `FAIL`. PASS pada dua SQL ini hanya membuka
gate berikutnya: komposisi Confirm SO -> Reservation + DO secara atomik. Itu
belum merupakan runtime fulfillment, smoke, atau UAT PASS.

## Contract-to-test map

| Kontrak bisnis | Implementasi schema | Postflight | Behavioral |
| --- | --- | --- | --- |
| DO awal langsung siap diproses | default `status = READY` | membaca default aktual dari catalog | insert tanpa status, assert `READY` |
| DO awal berjenis Initial | default `delivery_kind = INITIAL` | membaca default aktual dari catalog | insert tanpa kind, assert `INITIAL` dan parent kosong |
| DO tambahan hanya Backorder | check constraint `INITIAL/BACKORDER` | assert constraint tidak memuat `CORRECTION` | insert `BACKORDER` dengan parent DO awal |
| Context user mengikuti kontrak existing | default schema `selection_source` | constraint existing tidak diubah | insert tanpa literal `selection_source` buatan test |
| Belum ada efek final | runtime Confirm belum dipasang | inventory foundation saja | bandingkan row POS/Stock/Invoice/Finance sebelum-sesudah lalu rollback |

Correction/discrepancy pada DO yang sama dan Retur setelah penerimaan adalah
gate runtime berikutnya. Foundation ini tidak mengklaim keduanya sudah aktif.

## Rollback / forward-fix

Belum ada business row yang dibackfill. Sebelum runtime dipasang, rollback
development dapat menghapus lima relation baru dan unique identity tambahan
dalam urutan dependency terbalik. Setelah runtime menghasilkan business row,
gunakan forward-fix; jangan menghapus Reservation/DO/audit yang sudah menjadi
evidence operasional.
