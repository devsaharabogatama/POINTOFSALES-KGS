# ODR-6B.1 Reservation Stock Read Model

## Tujuan

Mengaktifkan kolom **Reserved** dan **Available** pada Inventory → Stock Real.
Reserved bersumber dari Reservation canonical berstatus `OPEN` atau
`PARTIALLY_DISPATCHED`. Available dihitung server-side:

`Available to Sell = On Hand - Reserved Out`

Tahap ini read-only. Ia tidak mengubah On Hand, FIFO, Movement, Reservation,
Order, Payment, Event, atau Journal. Dispatch/Received UI lengkap tetap tahap
ODR-6B berikutnya.

Backoffice membaca `get_inventory_stock_overview()`. POS membaca
`get_pos_stock_availability(store, warehouse)`, yang hanya menerima Store dan
Gudang milik sesi kasir aktif. Perhitungan Reserved POS mencakup seluruh Order
aktif pada Gudang tersebut, termasuk Order dari Store lain yang memakai Gudang
yang sama. Browser tidak diberi akses langsung ke tabel Reservation.

## Urutan rollout

1. `supabase/diagnostics/odr_phase6b_reservation_stock_read_model_preflight.sql`;
2. `supabase/migrations/20260829090000_odr_phase6b_reservation_stock_read_model.sql`;
3. `supabase/diagnostics/odr_phase6b_pos_stock_availability_forward_fix_preflight.sql`;
4. `supabase/migrations/20260829100000_odr_phase6b_pos_stock_availability_forward_fix.sql`;
5. `supabase/tests/odr_phase6b_reservation_stock_read_model_behavior.sql`;
6. `supabase/tests/odr_phase6b_reservation_stock_read_model_postflight.sql`;
7. deploy/restart Backoffice dan PWA terbaru lalu hard refresh;
8. buka Inventory → Stock Real dan cocokkan satu Order terkonfirmasi.

Preflight boleh menghasilkan `SETUP` dan `INFO`, tetapi tidak boleh
`BLOCKER`. Behavioral harus satu `PASS`. Postflight hanya boleh `PASS/INFO`.

Jika ledger `20260829090000` sudah ada, jangan menjalankan migration tersebut
ulang. Mulai dari forward-fix preflight pada langkah 3. Pemisahan version ini
wajib karena migration yang sudah tercatat tidak boleh ditimpa dengan runtime
baru.

## Smoke

Untuk Order contoh dengan 10 PACK dan 7 PACK:

- masing-masing Product menampilkan Reserved sesuai kebutuhan stock product;
- Available sama dengan On Hand dikurangi Reserved;
- On Hand dan Movement terakhir tidak berubah hanya karena membuka halaman;
- setelah Order tanpa Payment dibatalkan, Reserved kembali nol;
- setelah partial Dispatch, hanya sisa yang belum dikirim tetap Reserved.
- POS Store/Gudang yang tidak sama dengan sesi aktif ditolak server;
- dua Store yang memakai Gudang sama melihat pengurangan Available dari seluruh
  Reservation aktif Gudang tersebut;
- hard refresh PWA tidak mengembalikan angka katalog ke On Hand mentah.
