# Backoffice Sales Confirm Fulfillment Runtime

## Status

`DATABASE LIVE - ISOLATED DEVELOPMENT ONLY; DRY-RUN/APPLY PASS; MANUAL
POSTFLIGHT AND BEHAVIOR PASS PER USER; AUTHENTICATED SMOKE, CLIENT, AND UAT
PENDING`.

Target yang diizinkan hanya isolated Development `fkywtxucmyjvpwdiqpix`.
Production `nbxjslqojexjfogamnjt` dan staging lama
`yjxpddwrjdczuqyixqwi` tidak boleh disentuh.

## Kontrak tunggal

| Keputusan | Runtime | Bukti test |
| --- | --- | --- |
| Confirm SO membuat pemenuhan | satu Reservation dan satu DO `INITIAL/READY` dalam transaksi Confirm | assert SO, Reservation, DO, line, dan audit |
| Reservation selalu penuh | `reserved_base_qty = ordered_base_qty` | assert header dan line |
| Kekurangan hanya dengan opt-in Warehouse | hitung On Hand dikurangi Reserved POS dan Backoffice; tolak bila `allow_negative_stock=false` | denial atomic lalu success ketika opt-in |
| Bundle tetap virtual | resolver komponen canonical POS menghasilkan requirement Product fisik | definition/postflight; authenticated Bundle fixture masih pending |
| Retry tidak menggandakan | operation UUID Confirm existing tetap authority | exact retry mengembalikan ID Reservation/DO yang sama |
| Confirm belum final | tidak ada Stock Movement, FIFO, Invoice, Payment, Finance Event, atau Journal | before/after downstream counts |

SO confirmed historis tidak dibackfill. Migration hanya mengaktifkan komposisi
untuk Confirm baru. SO berubah ke fulfillment `PREPARING` karena DO `READY`
telah tersedia untuk Gudang; revisi/cancel sesudah titik ini tetap fail-closed
sampai runtime discrepancy/release dibuat pada gate berikutnya.

## Manual gate Development

Preflight dan migration sudah dijalankan ke Development. User sudah menjalankan:

1. `supabase/diagnostics/backoffice_sales_confirm_fulfillment_postflight.sql` — PASS.
2. `supabase/tests/backoffice_sales_confirm_fulfillment_behavior.sql` — sukses/PASS.

Behavioral me-rollback seluruh business row dan perubahan opt-in Warehouse. Ia
memilih master existing yang memenuhi constraint aktual dan tidak mengarang
`selection_source`. Karena PostgreSQL sequence bersifat non-transactional,
counter nomor Quotation/SO/SJ pada isolated Development dapat tetap maju selama
test; tidak ada dokumen bisnis yang tertinggal. Jangan menjalankan behavioral
ini di production.

Hentikan bila ada error SQL, `FAIL`, perubahan jumlah POS Reservation/SJ,
Stock Movement, Invoice, atau Financial Event. PASS SQL belum berarti Client,
authenticated smoke, atau UAT selesai.

## Forward-fix

Sebelum ada Confirm baru, migration dapat dibatalkan dengan mengembalikan
wrapper Confirm lama dan menghapus helper/kolom tambahan dalam urutan dependency
terbalik. Setelah Reservation/DO nyata tercipta, jangan drop atau menghapus
audit; gunakan forward-fix append-only.
