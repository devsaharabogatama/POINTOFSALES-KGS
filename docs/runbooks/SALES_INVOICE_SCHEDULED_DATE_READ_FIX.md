# Sales Invoice Scheduled Date Read Fix

## Outcome

Satu tanggal Invoice canonical dipakai oleh daftar/detail Backoffice, print/PDF,
print POS, dan export rentang. Untuk policy `ORDER_DATE`, Order `SCHEDULED`
memakai `planned_order_date`; `POSTED_DATE` tetap memakai waktu final/konfirmasi.

Forward-fix hanya mengganti read model dan renderer. Snapshot Invoice lama,
nomor dokumen, Order, Surat Jalan, Stock, Reservation, FIFO, Payment, periode,
Financial Event, dan Journal tidak dimutasi.

## Impact dan compatibility

- Invoice historical Scheduled yang sebelumnya terbaca pada tanggal pembuatan
  Draft akan muncul pada tanggal rencana Order yang benar.
- Akibat yang disengaja: keanggotaan rentang export Invoice tersebut ikut
  berpindah ke tanggal canonical.
- Respons RPC menambahkan `invoiceDate`; field existing tetap tersedia untuk
  rolling compatibility.
- Client baru menampilkan label `Tanggal Invoice`; fallback client saat database
  belum dimigrasi diberi label `Waktu konfirmasi`, bukan disebut tanggal Invoice.
- Snapshot immutable tidak ditulis ulang. Rollback data tidak diperlukan.

## Urutan rollout manual

Jalankan satu per satu di SQL Editor Supabase target:

1. `supabase/diagnostics/sales_invoice_scheduled_date_read_fix_preflight.sql`;
2. `supabase/migrations/20260907100000_sales_invoice_scheduled_date_read_fix.sql`;
3. `supabase/tests/sales_invoice_scheduled_date_read_fix_behavior.sql`;
4. `supabase/diagnostics/sales_invoice_scheduled_date_read_fix_postflight.sql`;
5. deploy Backoffice dan PWA, lalu hard refresh.

Hentikan pada SQL error, `BLOCKER`, atau `FAIL`. `REVIEW` pada preflight hanya
inventarisasi row historical yang akan dikoreksi saat dibaca; migration tidak
menulis ulang row tersebut.

## Authenticated smoke

1. Pada KMS, buka `INV-20260831-0000000157`.
2. Pastikan daftar dan detail menunjukkan `Tanggal Invoice 31/8/2026`.
3. Print dan unduh PDF; tanggal harus `31/08/2026`.
4. Export rentang 31 Agustus dan pastikan Invoice tersebut ada dengan tanggal
   `2026-08-31`; export hanya 29 Agustus tidak boleh lagi memuatnya.
5. Uji satu Invoice Immediate, satu Backorder, satu Scheduled baru, dan satu
   Company dengan `POSTED_DATE`.
6. Ulangi print/export untuk Invoice revisi dan pastikan nomor serta lineage
   tidak berubah.

## Rollback / forward-fix

Jangan mengubah snapshot atau data transaksi untuk rollback. Bila ditemukan
regresi, pertahankan migration ledger dan buat forward-fix pada resolver/read
model. Bundle lama tetap dapat berjalan karena field response existing tidak
dihapus.
