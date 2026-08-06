# G5 Phase 5 Goods Receipt Foundation Rollout

Status: local-ready, belum diterapkan ke database live.

## Tujuan

Membuka penerimaan Supplier Order secara online oleh Kasir dengan dukungan
partial/over receipt, kondisi baik/rusak/ditolak, Stock/FIFO/Movement atomic,
serta AP provisional dan Financial Event `HOLD`. Supplier Invoice, matching,
payment supplier, jurnal final, dan offline receipt tetap tertutup.

## Urutan manual

Jalankan seluruh file, satu per satu, tanpa menyalin komentar percakapan ke SQL
Editor:

1. `supabase/migrations/20260806040000_g5_phase5_goods_receipt_foundation.sql`
2. `supabase/migrations/20260806050000_g5_phase5_goods_receipt_history_trigger_fix.sql`
3. `supabase/diagnostics/g5_phase5_goods_receipt_postflight.sql`
4. `supabase/tests/g5_phase5_goods_receipt_foundation_tests.sql`
5. ulangi `supabase/diagnostics/g5_phase5_goods_receipt_postflight.sql`

Jika migration `20260806040000` sudah applied, jangan jalankan ulang. Mulai dari
forward-fix `20260806050000`, kemudian postflight dan behavioral test.

Migration dan behavioral test menulis data; behavioral test membungkus semua
fixture/effect dalam `BEGIN ... ROLLBACK`. Postflight SELECT-only.

## Hasil yang diterima

- seluruh baris postflight selain `INFO` berstatus `PASS`;
- behavioral test menghasilkan notice `TEST PASSED`;
- postflight kedua tetap seluruhnya `PASS`;
- tidak ada direct INSERT/UPDATE/DELETE bagi browser pada tabel receipt;
- satu replay `post_goods_receipt` dengan idempotency key yang sama tidak
  menggandakan Stock, FIFO, Movement, AP, atau Financial Event.

## Smoke setelah database PASS

Belum ada UI Phase 5 pada langkah ini. Jangan menganggap Goods Receipt sudah
aktif bagi user sebelum PWA menerima Supplier Order, menyimpan Draft, melakukan
Post, dan menampilkan hasil penerimaan. UI tersebut adalah next safe step.

## Compatibility dan forward-fix

- Supplier Order/Request existing tidak diubah bentuk datanya.
- Order `CONFIRMED/PARTIALLY_RECEIVED` menjadi sumber receipt; status dihitung
  ulang berdasarkan kuantitas receipt `POSTED`.
- Barang `REJECTED` tidak menambah Stock/FIFO/AP.
- Barang `DAMAGED` masuk Gudang tipe `DAMAGED` dan tetap menambah AP provisional.
- Finance hanya `HOLD_UNTIL_G6`; tidak ada Journal final.
- Bila rollout migration gagal, transaksi otomatis rollback. Setelah migration
  tercatat, koreksi wajib memakai forward migration baru—jangan edit migration
  applied.
