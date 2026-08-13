# ACP-4H Opening Stock Permission Preflight

Status: READY TO RUN; SELECT-only, belum mengubah runtime atau permission.

## Tujuan

Audit ini membuka tepat slice `inventory.opening_stock` setelah ACP-4G live.
Ia memeriksa:

- role approved: Store Manager/Finance menyiapkan Draft, Owner/Admin Posting;
- effective navigation/API/RPC dan helper lama;
- direct read/write tiga tabel Opening Stock;
- kebutuhan satu composed read dengan narrow Product/UOM/Gudang reference;
- Draft/Post lifecycle, optimistic version, idempotency, dan tenant reference;
- aturan hanya sebelum Movement pertama dan zero-cost reason;
- bukti POSTED pada Movement, balance, FIFO, Finance event, dan audit;
- rekonsiliasi Stock–Movement–FIFO global.

`REVIEW` dan `SETUP` adalah target desain, bukan izin otomatis untuk rollout.
`BLOCKER` wajib nol. Audit tidak mengubah schema, grant, dokumen, stock, FIFO,
Movement, event, atau permission status.

## Cara menjalankan

Jalankan seluruh file:

`supabase/diagnostics/acp_phase4h_opening_stock_permission_preflight.sql`

Kirim semua row `check_name,status,details`. Jangan jalankan enforcement bila
ada `BLOCKER`. Opening Stock tetap `SHADOW` hingga output direview dan paket
migration/postflight/behavior dibuat. Minimum Stock tetap di luar slice ini.

