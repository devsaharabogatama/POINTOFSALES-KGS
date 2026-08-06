# G5 Phase 8 Purchase Return Foundation Rollout

Status: local-ready; belum diterapkan ke database live.

## Tujuan

Membuka Purchase Return `PUR-004` dengan lifecycle terjaga:

1. Kasir membuat Draft online dari Goods Receipt `POSTED` dan sesi sendiri;
2. Store Manager/Company Admin/Super Admin melakukan review;
3. approve tidak membutuhkan alasan, reject/cancel membutuhkan alasan;
4. Post hanya setelah approve dan barang dianggap diserahkan ke Supplier;
5. Post mengurangi Stock serta batch FIFO sumber yang sama, membuat Movement
   `PURCHASE_RETURN`, AP adjustment append-only, audit, dan Financial Event
   `HOLD`;
6. Supplier Invoice, credit note/refund final, payment Supplier, dan jurnal GL
   tetap tertutup sampai G6.

## Urutan manual

Jalankan seluruh file terbaru secara berurutan di Supabase SQL Editor:

1. `supabase/migrations/20260806070000_g5_phase8_purchase_return_foundation.sql`
2. `supabase/diagnostics/g5_phase8_purchase_return_postflight.sql`
3. `supabase/tests/g5_phase8_purchase_return_foundation_tests.sql`
4. ulangi `supabase/diagnostics/g5_phase8_purchase_return_postflight.sql`

Migration dan behavioral test menulis data. Behavioral test membungkus seluruh
fixture/effect dalam `BEGIN ... ROLLBACK`. Postflight SELECT-only.

## Hasil yang diterima

- seluruh row postflight selain `INFO` berstatus `PASS`;
- behavioral test menghasilkan notice `TEST PASSED`;
- postflight penutup tetap seluruhnya `PASS`;
- replay key Post yang sama tidak menggandakan Stock, FIFO, Movement, AP
  adjustment, Event, atau audit Post;
- Draft/rejected/canceled tidak menghasilkan final effect;
- retur melebihi quantity receipt atau FIFO aktual ditolak;
- browser tidak memiliki direct write ke Return/Stock/FIFO/Movement/AP.

## Compatibility dan boundary

- Goods Receipt, Supplier Order, dan AP provisional sumber tidak ditulis ulang;
- AP provisional `OPEN` memperoleh adjustment route `AP_PROVISIONAL`;
- bila source AP sudah tidak `OPEN`, Return tetap dapat mencatat stock keluar,
  tetapi route menjadi `SUPPLIER_CREDIT_PENDING` untuk diselesaikan G6;
- Return dari kondisi `GOOD` atau `DAMAGED` mengurangi Gudang/batch sumbernya;
- barang yang sudah terjual, ditransfer, atau tidak lagi ada pada batch sumber
  tidak dapat diretur melalui dokumen ini;
- migration applied tidak boleh diedit atau dijalankan ulang. Koreksi setelah
  applied wajib berupa forward migration.

## Setelah rollout PASS

Next safe step adalah UI Purchase Return: Draft dari PWA dan review/post dari
Backoffice. Jangan membuka Supplier Invoice atau jurnal final lebih awal.
