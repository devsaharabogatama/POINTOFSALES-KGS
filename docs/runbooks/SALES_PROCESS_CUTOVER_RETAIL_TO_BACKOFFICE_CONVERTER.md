# Sales Process Cutover Retail to Backoffice Converter — Step 4B/6

Status: **DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS ON ISOLATED DEVELOPMENT**.

Step ini memasang kernel private untuk satu arah `Retail -> Backoffice` saja.
Belum ada public Apply RPC dan belum ada perubahan mode Company.

## Impact map

- Direct: source Retail nonfinal, target Quotation/SO Backoffice, line commercial
  snapshot, Reservation, DO awal, dan audit kedua dokumen.
- Downstream yang tetap nol: Stock Movement, FIFO/COGS, Payment baru, Finance
  Event/queue/Journal, procurement/PO, dan mode Company.
- Source baru ditutup setelah target Draft lengkap dan nilai komersial cocok.
  Untuk target confirmed, pembatalan source serta confirmation target berada
  dalam transaksi yang sama; kegagalan confirmation merollback semuanya.
- Lifecycle `DRAFT_INPUT` menjadi Draft Quotation. Lifecycle
  `CONFIRMED`/`RESERVED` serta row legacy yang benar-benar ber-runtime
  `SCHEDULED` menjadi confirmed SO dengan Reservation dan initial DO canonical.
- `order_timing_mode=SCHEDULED` bukan lifecycle `order_runtime_status=SCHEDULED`:
  Draft future canonical tetap berstatus runtime `DRAFT_INPUT`, sehingga tetap
  menjadi Draft Quotation dengan tanggal rencana dipertahankan.
- Pending Revision, procurement terbuka, Dispatch, Payment, dan final effect
  direvalidasi fail-closed.
- Store, Customer, gudang sumber penjualan, Product-UOM, Product, dan UOM harus
  masih aktif sesuai kontrak canonical Backoffice; ketidakcocokan ditolak dan
  tidak dimigrasikan diam-diam.
- Operation UUID yang sama untuk source yang sama mengembalikan target yang
  sama (`exactRetry=true`); reuse operation untuk source lain ditolak.
- Behavioral membentuk headroom stok rollback-only dari reservation aktual agar
  confirmation fixture tidak membuka procurement karena kondisi data lain.
  Tidak ada Stock Movement palsu dan transaksi selalu berakhir `ROLLBACK`.
- Fixture confirmed harus TEMPO agar tidak membuat payment request yang akan
  menjadikannya tidak eligible. Test membuat atau membuka sementara periode
  bulan berjalan di transaksi yang sama; perubahan periodenya ikut `ROLLBACK`.

## Urutan manual

Target hanya Supabase Development `fkywtxucmyjvpwdiqpix`.

1. Jalankan [preflight](../../supabase/diagnostics/sales_process_cutover_retail_to_backoffice_converter_preflight.sql).
2. Stop pada SQL error atau `BLOCKER`.
3. Jalankan [migration 20260911100000](../../supabase/migrations/20260911100000_sales_process_cutover_retail_to_backoffice_converter.sql).
4. Jalankan [behavioral rollback](../../supabase/tests/sales_process_cutover_retail_to_backoffice_converter_behavior.sql).
5. Jalankan [postflight](../../supabase/diagnostics/sales_process_cutover_retail_to_backoffice_converter_postflight.sql).
6. Kirim seluruh hasil. Jangan menjalankan file ini pada production/staging.

## Authenticated smoke boundary

- Positive conversion belum diekspos sebagai RPC browser pada Step 4B; belum
  ada tombol/UI yang dapat menjalankan kernel ini.
- Smoke authenticated pada gate ini memverifikasi role `authenticated` tidak
  dapat mengeksekusi fungsi `private` dan public Apply belum tersedia.
- Positive authenticated end-to-end conversion wajib menunggu public Apply.
  Sampai itu tersedia, status tidak boleh disebut `CLIENT DEPLOYED`,
  `SMOKE PASS`, atau `UAT PASS`.

## Rollback / forward-fix

Sebelum `COMMIT`, error merollback fungsi dan ledger. Setelah applied, migration
tidak diedit atau dihapus. Defect ditutup dengan forward migration. Karena Apply
publik belum ada, operator belum dapat menjalankan conversion melalui UI/RPC.
