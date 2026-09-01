# ODR Dispatch Runtime Schema Forward-Fix

## Masalah

Dispatch Surat Jalan linked-Order berhenti dengan pesan generik
`SALES_DELIVERY_OPERATION_FAILED`. Audit transaksi rollback membuktikan dua
drift runtime pada core ODR-3C:

1. `digest(...)` dipanggil tanpa schema, sementara fungsi pgcrypto berada di
   `extensions.digest(...)` dan `search_path` runtime sengaja dibatasi;
2. runtime membaca `sale_stock_requirements.stock_sku/stock_name`, padahal
   identitas tersebut berada pada `products.sku/name`.

Kegagalan terjadi sebelum perubahan Dispatch di-commit. Dokumen tetap `READY`,
Reservation tetap terbuka, dan tidak ada Movement/Event/Journal parsial.

## Scope

Forward-fix hanya mengganti definisi private stock core yang sudah aktif.
Contract public RPC, permission, atomic transaction, idempotency, Reservation,
FIFO, stok-minus, Movement, Finance, dan legacy Delivery tidak diubah.

## Urutan manual

1. Jalankan
   `supabase/diagnostics/odr_dispatch_runtime_schema_forward_fix_preflight.sql`.
   `BACKFILL` hanya di `dispatch_runtime_schema_compatibility` adalah defect yang
   memang diperbaiki migration. Hentikan bila ada `BLOCKER`.
2. Jalankan
   `supabase/migrations/20260901100000_odr_dispatch_runtime_schema_forward_fix.sql`.
3. Jalankan
   `supabase/tests/odr_dispatch_runtime_schema_forward_fix_behavior.sql`.
4. Jalankan
   `supabase/tests/odr_dispatch_runtime_schema_forward_fix_postflight.sql`.
   Semua check selain inventory wajib `PASS`.
5. Restart/deploy Backoffice yang memuat error mapping terbaru, hard refresh,
   lalu ulangi Dispatch dokumen yang sebelumnya gagal.
6. Jalankan kembali postflight ODR-6B.2:
   `supabase/tests/odr_phase6b_inventory_dispatch_ui_postflight.sql`.

## Smoke wajib

- full Dispatch untuk Order dengan seluruh stok berasal dari izin stok-minus;
- cek SJ menjadi `DISPATCHED`, Reservation `CONSUMED`, On Hand/Available,
  negative allocation, Movement, dan Finance Event `HOLD` pada mode Controlled;
- ulangi request dengan idempotency key yang sama dan pastikan tidak ada efek
  kedua;
- lakukan partial Dispatch pada dokumen lain bila tersedia, lalu Received;
- seluruh reconciliation postflight harus `PASS`.

## Rollback / forward-fix

Migration tidak melakukan backfill data. Jika deployment frontend harus
dibatalkan, rollback frontend tidak mengubah database. Fungsi database tidak
boleh dikembalikan ke referensi lama karena versi lama selalu gagal pada
runtime; koreksi lanjutan harus memakai forward migration baru.
