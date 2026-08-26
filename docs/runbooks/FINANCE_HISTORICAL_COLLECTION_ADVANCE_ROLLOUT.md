# F3 Historical Collection and Customer Advance Rollout

Status: **migration dan postflight local-ready; rollout menunggu user**.

Jalankan berurutan:

1. [`finance_historical_collection_advance_preflight.sql`](../../supabase/diagnostics/finance_historical_collection_advance_preflight.sql)
2. [`20260827120000_finance_historical_collection_customer_advance.sql`](../../supabase/migrations/20260827120000_finance_historical_collection_customer_advance.sql)
3. [`finance_historical_collection_advance_postflight.sql`](../../supabase/diagnostics/finance_historical_collection_advance_postflight.sql)

F3 menutup dua jalur berbeda:

1. **Invoice sudah ada:** tanggal penerimaan boleh memakai tanggal pembayaran
   aktual walaupun lebih awal daripada tanggal order/backorder yang baru diinput.
   Dana dialokasikan ke piutang dan jurnal tetap `Dr Cash/Bank; Cr AR`.
2. **Invoice belum ada:** dana hanya boleh disimpan sebagai advance eksplisit
   ketika Customer Balance Company `ACTIVE`. Jurnal menjadi
   `Dr Cash/Bank; Cr Customer Balance Liability`; dana tidak boleh otomatis
   menjadi revenue atau dianggap membayar invoice yang belum ada.

Company tanpa Customer Balance tetap dapat memakai jalur pertama. Jalur advance
harus fail-closed dan tidak boleh otomatis mengaktifkan Customer Balance.

Migration sengaja menolak state awal yang sudah mempunyai Customer Receipt agar
backfill tidak ditebak. Preflight target saat ini membuktikan tabel masih kosong.
Lima policy `DISABLED` dipertahankan; postflight akan gagal bila migration secara
tidak sengaja mengaktifkan salah satunya.
