# ODR-5C Dispatch Finance Runtime

Status: `LOCAL READY`  
Migration: `20260828230000`

## Tujuan

Memasang final effect Finance Dispatch tanpa mengubah alur verifikasi Payment:

- satu operasi Dispatch menghasilkan tepat satu source Finance immutable dan
  satu Financial Event `SALE_DISPATCHED` berstatus `HOLD`;
- capture Finance berada dalam transaksi yang sama dengan pengurangan
  Reservation, On Hand, FIFO, dan Movement;
- partial Dispatch mengalokasikan nilai Product dan Tax secara proporsional;
  Dispatch terakhir menutup residual Tax, ongkir, surcharge, dan rounding;
- HPP memakai FIFO aktual serta total provisional cost yang dipakai runtime
  negative-stock Dispatch;
- controlled queue dapat memposting jurnal Dispatch yang balance;
- jurnal legacy tetap immutable.

ODR-5D verifikasi Payment, automatic posting, dan UI ODR-6 belum dibuka.

## Urutan manual

Jalankan file secara utuh dan satu per satu di Supabase SQL Editor:

1. Migration:
   [`20260828230000_odr_phase5c_dispatch_finance_runtime.sql`](../../supabase/migrations/20260828230000_odr_phase5c_dispatch_finance_runtime.sql)
2. Postflight:
   [`odr_phase5c_dispatch_finance_runtime_postflight.sql`](../../supabase/tests/odr_phase5c_dispatch_finance_runtime_postflight.sql)
3. Behavioral fixture-free:
   [`odr_phase5c_dispatch_finance_runtime_behavior.sql`](../../supabase/tests/odr_phase5c_dispatch_finance_runtime_behavior.sql)
4. Jalankan ulang postflight.

Hentikan rollout pada SQL error atau satu pun row `FAIL`. Inventory `INFO`
boleh nol karena belum ada Order ODR live.

## Expected

- semua check postflight selain inventory berstatus `PASS`;
- behavioral menghasilkan satu row `PASS` dan `writesPersisted=false`;
- `automatic_posting_remains_closed=PASS`;
- belum ada source/event/jurnal ODR bila belum ada Dispatch baru;
- jurnal historis existing tetap tidak berubah.

## Smoke setelah closing PASS

Gunakan Company dummy dengan periode tanggal hari ini `OPEN`:

1. Confirm satu Order non-TEMPO dan pastikan hanya reservation yang bertambah;
2. Dispatch sebagian dari Backoffice Inventory;
3. pastikan On Hand/FIFO/Movement berubah sekali, satu effect dan satu event
   `HOLD` terbentuk, dan exact retry tidak menambah row;
4. buat controlled preview, approve, lalu process;
5. cek satu jurnal `SALE_DISPATCHED` balance dan Inventory GL sama dengan cost
   Dispatch;
6. Dispatch sisa, proses controlled queue lagi, lalu pastikan akumulasi Revenue,
   Tax, ongkir, surcharge, dan rounding sama dengan snapshot Invoice;
7. ulangi satu Order TEMPO: sisi debit Dispatch harus Customer Receivable;
8. jangan mencoba verifikasi Payment sampai ODR-5D selesai.

## Forward fix

Migration bersifat transactional dan tidak melakukan backfill. Bila migration
gagal, seluruh rename/wrapper/schema ikut rollback. Setelah migration sukses,
jangan menghapus effect/event/jurnal; koreksi memakai forward migration. Mode
`AUTOMATIC` sengaja ditolak server sampai ledger ODR-5D tersedia.
