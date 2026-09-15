# Purchase Daily Replenishment Step 1/6

## Dampak

Paket ini menambahkan setting per Company, urutan Product-Supplier, serta tabel pengelompokan harian yang belum mempunyai generator. Default seluruh Company adalah `MANUAL`. Tidak ada Stock, FIFO, Request Order, Supplier Order, Goods Receipt, AP, Financial Event, Journal, Sales, atau POS yang dibuat/diubah oleh runtime paket ini.

## Urutan isolated Development

Jalankan file lengkap melalui Supabase SQL Editor project `fkywtxucmyjvpwdiqpix`:

1. `supabase/diagnostics/purchase_daily_replenishment_foundation_preflight.sql`;
2. pastikan tidak ada `BLOCKER`;
3. `supabase/migrations/20260913100000_purchase_daily_replenishment_foundation.sql`;
4. `supabase/diagnostics/purchase_daily_replenishment_foundation_postflight.sql`;
5. `supabase/tests/purchase_daily_replenishment_foundation_behavior.sql`;
6. ulangi postflight.

Semua check selain `INFO` wajib `PASS`. Behavioral memakai actor sendiri, memakai Company aktif hanya sebagai tenant fixture, dan seluruh perubahan dibungkus `BEGIN/ROLLBACK`.

## Authenticated smoke setelah SQL PASS

1. Restart Backoffice isolated Development.
2. Login `localadmin@local.com` dan buka Pengaturan Modul > Purchase.
3. Pastikan default `Manual`.
4. Ubah ke `Otomatis buat RO`, muat ulang, dan pastikan pilihan bertahan.
5. Ubah ke `Otomatis buat PO`, muat ulang, dan pastikan pilihan bertahan.
6. Kembalikan ke `Manual` selama generator Step 2-6 belum live.
7. Login user non-Super Admin: setting terbaca tetapi tidak dapat diubah.
8. Pastikan Supplier Order, Penerimaan Barang, POS dan Finance existing tetap terbuka sesuai permission sebelumnya.

## Rollback / forward repair

Sebelum ada batch runtime, rollback client adalah menghapus panel setting. Schema jangan di-drop bila audit setting sudah terbentuk. Jika migration gagal, transaksi PostgreSQL rollback seluruhnya. Setelah migration applied, koreksi wajib migration forward baru; jangan mengedit file `20260913100000`.
