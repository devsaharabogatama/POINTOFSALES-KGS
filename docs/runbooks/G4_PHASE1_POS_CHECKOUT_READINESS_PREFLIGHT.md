# G4 Phase 1 — POS Checkout Readiness Preflight

## Tujuan

Gate ini menginventarisasi kondisi live sebelum canonical POS Session dan
checkout dibuat. File diagnostic hanya membaca schema/data dan tidak membuka
checkout.

Requirement utama:

- `POS-001`: Session terikat Company, Store, Terminal, Cashier, dan Gudang jual;
- `POS-002`: harga, Tax, discount, rounding, stock, FIFO/HPP, serta payment
  dihitung ulang server;
- `POS-003`: kekurangan stok menghasilkan Draft tanpa efek stock/Finance;
- `POS-004`: client transaction ID dan idempotency menjadi dasar offline retry;
- `STK-005`: Sale mengonsumsi FIFO;
- `STK-006`: Bundle Sale mengurangi komponen, bukan stok Bundle.

## Boundary

Jalankan:

`supabase/diagnostics/g4_phase1_pos_checkout_readiness_preflight.sql`

Diagnostic mengaudit:

- dependency Pricelist, Payment Method, Tax resolver, dan G3 Bundle;
- Store, Terminal, Gudang jual, Payment Method, Customer Walk-In, Product-UOM,
  serta Bundle readiness;
- duplicate/open Cashier Session dan assignment Cashier;
- schema snapshot Session, Sale header/detail, rounding, UOM, offline identity,
  FIFO, dan Bundle allocation;
- exposure RPC checkout legacy;
- apakah harga/HPP/total masih dipercaya dari payload client;
- history Sale lama terhadap Movement dan Financial Event;
- direct browser table-write closure.

## Expected pada Baseline Sekarang

Beberapa `BLOCKER` memang expected dan menjadi alasan G4 belum dibuka:

- RPC `create_sales_transaction` legacy masih executable;
- implementation legacy masih menerima harga, HPP, dan total dari client;
- server price resolver canonical belum tersedia;
- canonical Draft/Post Session/Sale runtime belum tersedia.

Expected gap bukan izin mengabaikannya. Migration G4 baru boleh dirancang
setelah seluruh output live diterima dan data history/backfill scope diketahui.

`SETUP` berarti konfigurasi Store/Terminal/Gudang jual/Payment Method belum
lengkap. `INFO` pada missing columns/tables adalah input desain migration,
bukan kegagalan query.

## Cara Menjalankan

1. Buka Supabase SQL Editor.
2. Jalankan seluruh file preflight.
3. Kirim semua row `check_name,status,details`.
4. Jangan menjalankan `supabase/checkout_rpc.sql`.
5. Jangan memakai endpoint checkout Backoffice/PWA untuk transaksi nyata.

## Next Safe Step

Setelah output diterima:

1. pisahkan backfill/data blocker dari schema/runtime blocker;
2. desain foundation Session + Sale Draft/Post secara additive;
3. retire browser execution RPC legacy sebelum canonical checkout dibuka;
4. bangun server resolver dan atomic stock/FIFO/Bundle posting;
5. PWA production cutover dan offline queue dilakukan setelah database behavior
   lulus, bukan bersamaan dengan preflight.

Tidak ada migration atau rollback database pada fase SELECT-only ini.
