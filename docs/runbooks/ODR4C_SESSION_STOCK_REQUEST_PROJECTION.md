# ODR-4C — Proyeksi Demand Sesi ke Stock Request

## Outcome

Saat sesi kasir ditutup, kekurangan reservasi Order pada sesi tersebut dibentuk
menjadi satu Stock Request `SUBMITTED` yang dapat dibaca Purchasing. Item
digabung per Product dalam base UOM. Fase ini tidak membuat atau mengubah PO,
Stock On Hand, FIFO, Movement, Financial Event, atau Journal.

Selama sesi masih `OPEN`, konfirmasi/pembatalan Order hanya memperbarui demand
internal. Stock Request baru diproyeksikan setelah sesi ditutup agar Purchasing
tidak menerima request yang masih berubah-ubah.

## Urutan manual

1. Jalankan migration:
   `supabase/migrations/20260828170000_odr_phase4c_session_stock_request_projection.sql`.
2. Jalankan postflight:
   `supabase/tests/odr_phase4c_session_stock_request_postflight.sql`.
3. Jalankan behavioral test:
   `supabase/tests/odr_phase4c_session_stock_request_behavior.sql`.
4. Jalankan postflight kembali.

Semua baris selain `INFO` wajib `PASS`.

## Smoke manual

1. Buat dua Order pada satu sesi dengan Product shortage yang sama.
2. Pastikan sebelum tutup sesi belum ada Stock Request
   `SALES_ORDER_RESERVATION`.
3. Tutup sesi.
4. Buka Purchasing dan pastikan muncul satu Stock Request `SUBMITTED`.
5. Pastikan quantity Product merupakan jumlah shortage kedua Order.
6. Pastikan tidak ada PO baru, Stock Movement, atau jurnal baru dari langkah
   tersebut.

## Compatibility dan forward-fix

- Stock Request manual dan `NEGATIVE_STOCK_SESSION_CLOSE` tetap dipertahankan.
- Request otomatis reservasi tidak dapat dibatalkan manual.
- Migration additive; bila rollout gagal, transaksi akan rollback seluruhnya.
- Setelah migration berhasil, gunakan forward-fix, bukan menghapus request atau
  demand history.
- Sinkronisasi Draft PO dan amendment PO final sengaja belum dibuka; itu adalah
  boundary fase berikutnya.
