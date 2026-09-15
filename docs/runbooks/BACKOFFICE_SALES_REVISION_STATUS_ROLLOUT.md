# Backoffice Sales Revision and Status Rollout

## Status

`DATABASE + MANUAL POSTFLIGHT + ROLLBACK BEHAVIOR PASS — ISOLATED DEVELOPMENT
ONLY; CLIENT LOCAL BUILD PASS; AUTHENTICATED SMOKE AND UAT PENDING`.

## Locked behavior

- Jalur UI baru tidak menampilkan `Tandai Terkirim` untuk Quotation. Status
  legacy `SENT` tetap dapat dibaca/dikonfirmasi untuk compatibility.
- List dipisah menjadi tab Quotation dan Sales Order.
- Sales Order menyimpan status pemenuhan server-derived: `Dikonfirmasi`,
  `Disiapkan`, `Dikirim sebagian`, `Dalam perjalanan`, `Selesai`, atau
  `Dibatalkan`.
- `Dalam perjalanan` berarti barang telah berangkat. `Selesai` berarti Customer
  telah menerima dan perubahan berikutnya wajib memakai Retur.
- Revisi mempertahankan nomor SO/Quotation, wajib alasan, menaikkan version,
  dan membuat audit immutable berisi aktor/waktu/alasan.
- Runtime saat ini hanya membuka revisi pada `Dikonfirmasi`, karena Reservation/
  DO delta reconciler belum tersedia. Setelah fulfillment dimulai, revisi
  fail-closed agar data gudang tidak berbeda dari SO.
- SO boleh dibatalkan hanya sebelum fulfillment dimulai.
- Filter list memakai status SO dan date basis eksplisit: Order, Rencana Kirim,
  atau Jatuh Tempo.

## Manual gate

Jalankan pada Supabase Development `fkywtxucmyjvpwdiqpix`:

1. `supabase/diagnostics/backoffice_sales_revision_status_postflight.sql`
2. `supabase/diagnostics/backoffice_sales_activity_cancel_postflight.sql`
3. `supabase/diagnostics/backoffice_sales_revision_commercial_reset_fix_postflight.sql`
4. `supabase/tests/backoffice_sales_revision_status_behavior.sql`

Forward-fix `20260909144000` menjaga `backoffice_sales_orders_amount_check`
tetap aktif. Saat revisi membangun ulang lines, seluruh header commercial
direset atomik ke nilai nol yang konsisten sebelum calculator canonical menulis
subtotal, diskon, pajak, rounding, dan grand total final.

Hentikan pada error atau status `FAIL/BLOCKER`. Setelah SQL PASS, restart
Backoffice, hard refresh, lalu smoke dua tab, seluruh filter tanggal/status,
revisi bernomor sama, riwayat activity, exact retry/stale version, cancel SO
sebelum fulfillment, dan role/cross-Company denial.

## Delivery Order boundary

Confirm saat ini masih tidak membuat Reservation/SJ. Schema SJ retail aktif
mewajibkan `sales_id` dan `invoice_snapshot_id`, sedangkan flow Backoffice
mewajibkan DO sebelum Invoice. Fase fulfillment harus membangun lineage
Backoffice yang additive; dilarang mengisi Invoice dummy atau memanggil Confirm
POS sebagai jalan pintas.

Compatibility production harus diaudit read-only menggunakan
`supabase/diagnostics/backoffice_sales_production_compatibility_preflight.sql`
sebelum paket migration production disusun. Script tersebut belum dijalankan
ke production dan bukan izin deployment.

User melaporkan seluruh postflight dan behavioral di atas PASS pada
2026-09-09. Ini menutup database gate revisi/status, tetapi bukan authenticated
smoke atau UAT production.
