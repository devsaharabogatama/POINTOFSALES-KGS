# ODR-5B Finance Mapping and Runtime Preflight

Status: `LOCAL READY`  
Jenis: `SELECT-only`

## Tujuan

Membuktikan kesiapan mapping dan dispatcher sebelum ODR-5 membuat Financial
Event atau Journal untuk Dispatch dan verifikasi Payment.

Audit ini memeriksa:

- dependency ODR-5A dan Finance closure;
- collision kategori transaksi dedicated;
- kandidat akun deterministic per Company;
- kebutuhan akun `CUSTOMER_ADVANCE_LIABILITY`;
- enum event legacy yang aman untuk compatibility;
- approved posting rule, dispatcher, dan controlled queue support;
- zero-runtime source serta boundary jurnal historis.

## Cara menjalankan

Jalankan:

[`odr_phase5b_finance_mapping_runtime_preflight.sql`](../../supabase/diagnostics/odr_phase5b_finance_mapping_runtime_preflight.sql)

Kirim seluruh output tanpa mengubah status atau data secara manual.

## Interpretasi

- `BLOCKER`: hentikan; ada dependency atau identity collision.
- `BACKFILL`: migration berikutnya harus menyediakan mapping deterministic.
- `SETUP`: runtime/category/rule memang belum dipasang.
- `REVIEW`: scope conditional atau collision COA harus ditinjau dari output.
- `PASS`: kontrak saat ini aman.
- `INFO`: inventory saja.

Expected setelah ODR-5A dan sebelum ODR-5B runtime:

- kategori, approved rule, dispatcher, dan queue support masih `SETUP`;
- Customer Advance kemungkinan `BACKFILL` pada Company yang belum mempunyai
  akun dedicated;
- source ODR tetap nol;
- active queue dan journal balance tetap bersih.

Preflight ini tidak memberi izin mengaktifkan automatic posting. Migration
mapping/runtime baru dibuat setelah semua `BLOCKER` dan setiap `BACKFILL` atau
`REVIEW` ditinjau.
