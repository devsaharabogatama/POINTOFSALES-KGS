# ODR-3 Delivery Dispatch Stock Preflight

## Tujuan

Membuktikan kondisi live sebelum Dispatch mengambil alih pengurangan On Hand,
FIFO, dan Stock Movement dari jalur Post POS lama. Audit ini SELECT-only dan
tidak membuat reservation, Invoice, Surat Jalan, movement, atau jurnal.

## Jalankan

1. Pastikan ODR-2B migration, behavioral, dan closing postflight sudah PASS.
2. Jalankan
   `supabase/diagnostics/odr_phase3_delivery_dispatch_stock_preflight.sql`.
3. Kirim seluruh hasil `check_name,status,details`.

## Interpretasi

- `BLOCKER`: invariant/data live harus diperbaiki sebelum schema ODR-3 dibuat.
- `BACKFILL`: order reserved existing membutuhkan document snapshot terkontrol.
- `REVIEW`: collision arsitektur existing yang menentukan bentuk migration;
  bukan izin untuk memutasi histori legacy.
- `SETUP`: allocation, partial lifecycle, dan runtime ODR-3 memang belum ada.
- `PASS`/`INFO`: aman atau inventory saja.

## Batas wajib

- Delivery milik `LEGACY_POSTED` tidak diberi efek Stock kedua.
- Delivery printable tetap memakai commercial line; Dispatch memakai lineage
  reservation stock requirement agar Bundle mengonsumsi komponennya.
- Partial Dispatch tidak boleh melebihi reservation terbuka.
- Satu Dispatch atomik mengurangi reservation, On Hand, FIFO, dan membuat satu
  Movement source-linked; retry tidak membuat efek kedua.
- `DELIVERED` hanya bukti penerimaan dan tidak mengurangi Stock lagi.
- Finance Dispatch tetap ODR-5; ODR-3 tidak membuat jurnal.

