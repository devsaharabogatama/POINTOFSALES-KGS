# ODR-5 Finance Dispatch dan Verifikasi Payment — Preflight

Status: `LOCAL READY — SELECT-ONLY`  
Tanggal: 2026-08-28

## Tujuan

Mengaudit data live sebelum menambah final effect Finance untuk Order ODR:

- Dispatch membuat ekonomi Sale/AR atau clearing serta COGS/Inventory;
- verifikasi Payment menyelesaikan AR/clearing ke Cash/Bank;
- pembayaran sebelum Dispatch tetap advance/clearing dan bukan revenue;
- partial Dispatch tidak menggandakan revenue, tax, FIFO, atau jurnal;
- jurnal historis dari jalur Sale `POSTED` lama tetap immutable.

Preflight ini tidak menulis database.

## Cara menjalankan

Jalankan seluruh isi berikut di Supabase SQL Editor:

[`supabase/diagnostics/odr_phase5_finance_dispatch_payment_preflight.sql`](../../supabase/diagnostics/odr_phase5_finance_dispatch_payment_preflight.sql)

Pastikan tidak ada potongan query yang sedang terseleksi di SQL Editor. Gunakan
`Ctrl+A`, tempel ulang seluruh isi file, lalu **Run**; Supabase hanya menjalankan
teks yang terseleksi bila selection masih aktif.

Kirim seluruh output `check_name,status,details` sebelum migration ODR-5 dibuat.

## Interpretasi

- `BLOCKER`: hentikan rollout dan perbaiki data/kontrak terlebih dahulu.
- `BACKFILL`: mapping akun belum siap; jangan membuat event Finance dulu.
- `REVIEW`: inventaris keputusan cutover, bukan kegagalan data.
- `SETUP`: schema/runtime ODR-5 memang belum dibuat pada tahap preflight.
- `PASS`/`INFO`: aman untuk analisis lanjutan.

`odr_finance_event_catalog_state` dan `odr_finance_runtime_state` berstatus
`SETUP` adalah expected. Preflight ini sengaja tidak membuat migration sebelum
jumlah Dispatch, payment intent, partial Dispatch, mapping akun, dan periode
live diketahui.

## Boundary

- Jangan menjalankan ulang posting `SALE_POSTED` untuk Order ODR.
- Jangan mengubah jurnal historis atau mengisi `sales_payments` saat Order baru
  dikonfirmasi.
- Jangan mengakui revenue ketika payment diverifikasi sebelum Dispatch.
- Jangan mengaktifkan mode `AUTOMATIC` sebelum controlled queue, exact retry,
  journal balance, FIFO-GL, AR, dan cash-session reconciliation lulus.

## Rollback

Tidak diperlukan karena file ini hanya `SELECT`.
