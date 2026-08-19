# Rollout Stok Minus POS ke Permintaan Barang per Sesi

## Tujuan

Penjualan online non-Bundle yang mendapat otorisasi stok minus tetap `POSTED`.
Saat sesi kasir ditutup, kekurangan sesi yang masih belum direplenish digabung
per Product dan menghasilkan tepat satu Permintaan Barang berstatus `SUBMITTED`.
Purchasing kemudian dapat membagi baris permintaan tersebut ke Supplier Order
yang berbeda tanpa membuat permintaan ganda.

## Kontrak

- Stok minus tetap membutuhkan entitlement, policy Company, opt-in Gudang, dan
  izin user aktif untuk Gudang sesi.
- Offline dan Bundle tetap tidak mendukung stok minus.
- Sumber permintaan adalah allocation shortage Sale yang immutable, bukan saldo
  negatif Gudang secara umum.
- Kuantitas otomatis adalah `shortage_base_qty - replenished_base_qty` saat
  penutupan sesi dan memakai Base UOM.
- Satu sesi menghasilkan nol atau satu dokumen otomatis.
- Dokumen otomatis langsung `SUBMITTED`, tidak dapat dibatalkan, dan dapat
  dialokasikan Purchasing ke satu atau beberapa Supplier Order.
- Penutupan sesi, snapshot negatif, pembuatan request, line, lineage, submit,
  serta audit berlangsung dalam satu transaksi. Kegagalan menggagalkan semua.
- Retry penutupan dengan nominal Cash yang sama mengembalikan dokumen yang sama.

## Urutan rollout

1. Jalankan `supabase/diagnostics/negative_stock_session_request_preflight.sql`.
   `BLOCKER` harus nol; schema baru harus tampil `SETUP`.
2. Jalankan migration
   `supabase/migrations/20260819170000_negative_stock_session_replenishment_request.sql`.
3. Restart/reload PostgREST bila schema cache belum otomatis berubah.
4. Jalankan
   `supabase/diagnostics/negative_stock_session_request_postflight.sql`.
   Seluruh check selain inventory harus `PASS`.
5. Jalankan rollback-safe behavioral test
   `supabase/tests/negative_stock_session_request_tests.sql` sampai muncul
   `TEST PASSED`.
6. Jalankan regression berikut secara berurutan:
   - `supabase/tests/g4_phase2_cashier_session_foundation_tests.sql`;
   - `supabase/tests/g4_phase60_negative_stock_online_runtime_tests.sql`;
   - `supabase/tests/g5_phase2_stock_request_supplier_order_tests.sql`;
   - `supabase/tests/acp_phase5c_supplier_order_permission_tests.sql`.
7. Jalankan ulang postflight baru. Stop bila ada `FAIL`.
8. Deploy ulang PWA dan Backoffice, lalu hard refresh.

## UAT minimum

1. Aktifkan entitlement, policy, Gudang, dan izin user kasir yang sama persis.
2. Jual Product stok biasa melebihi stok saat POS online.
3. Isi alasan jika policy mewajibkan; Sale harus `POSTED`, bukan Draft.
4. Tutup sesi. Notice harus menyebut nomor Permintaan Barang otomatis.
5. Di Backoffice Purchasing, permintaan tampil dengan badge
   `Otomatis · stok minus sesi` dan kuantitas shortage yang tepat.
6. Buat Supplier Order hanya untuk salah satu baris; baris yang teralokasi tidak
   boleh kembali ditawarkan, sedangkan baris lain tetap tersedia.
7. Retry penutupan sesi atau refresh tidak boleh membuat request kedua.
8. Buka/tutup sesi berikutnya tanpa Sale minus; shortage sesi lama tidak boleh
   ikut ke request baru.

## Compatibility dan batasan

- Request manual, Supplier Order, Goods Receipt, rekonsiliasi FIFO, dan Finance
  tidak berubah.
- Barang masuk tetap merekonsiliasi allocation stok minus sesuai runtime G4.
- Request yang telah dibuat tidak otomatis mengecil setelah barang masuk karena
  ia merupakan bukti kebutuhan pada waktu penutupan. Purchasing dapat melihat
  asal otomatis dan mengambil keputusan order sebelum membuat Supplier Order.
- Tidak ada background worker; konsistensi dijaga secara atomik saat close.

