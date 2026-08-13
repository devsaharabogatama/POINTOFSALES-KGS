# SLD-R4 Explicit Delivery-Fee Return Rollout

**Status:** LOCAL READY; manual Supabase rollout pending  
**Migration:** `20260811150000_sld_r4_explicit_delivery_fee_return.sql`

## Outcome

- Partial Product Return tidak pernah mengembalikan ongkir.
- Full remaining Return menawarkan keputusan eksplisit `Refund ongkir`.
- Default keputusan adalah tidak refund ongkir.
- Nilai barang, ongkir, payment refund, approval, audit, dan `SALES_REFUND`
  event snapshot direkonsiliasi server-side.
- Store Manager/Admin melihat keputusan ongkir sebelum posting final.
- Finance event tetap `HOLD`; SLD-R4 tidak membuka posting expression G6.

## Urutan Manual

Jalankan tiap file sebagai query terpisah dan hentikan bila ada error:

1. preflight (sudah dilaporkan user tanpa `BLOCKER`):
   `supabase/diagnostics/sld_r4_delivery_fee_return_preflight.sql`;
2. migration:
   `supabase/migrations/20260811150000_sld_r4_explicit_delivery_fee_return.sql`;
3. postflight:
   `supabase/diagnostics/sld_r4_delivery_fee_return_postflight.sql`;
4. rollback-safe behavior:
   `supabase/tests/sld_r4_delivery_fee_return_tests.sql`;
5. regression minimum:
   `supabase/tests/g4_phase26_sales_return_foundation_tests.sql`, lalu
   `supabase/tests/sld_r2_delivery_fee_tests.sql`.

Postflight wajib seluruhnya `PASS` atau documented `INFO/DEFERRED`; tidak boleh
ada `FAIL`.

## Authenticated UI UAT

1. Buat Sale Delivery dengan ongkir dan Product quantity sedikitnya dua.
2. Kasir membuat partial Return. Opsi refund ongkir tidak boleh muncul.
3. Kasir memilih seluruh sisa Product. Opsi refund ongkir muncul, default OFF.
4. Simpan satu Draft tanpa refund ongkir; total hanya nilai barang.
5. Store Manager/Admin membuka detail dan melihat keputusan ongkir eksplisit,
   lalu batalkan Draft tersebut.
6. Ulangi full Return dengan opsi refund ongkir ON. Total harus menambahkan
   ongkir tepat satu kali.
7. Approver melihat nilai barang dan ongkir, lalu posting.
8. Verifikasi Return POSTED, Payment refund, Stock/FIFO restoration, dan satu
   `SALES_REFUND` HOLD event. Retry posting tidak boleh menggandakan efek.
9. Dengan Company kedua, pastikan list/detail/RPC Return Company pertama tidak
   terbaca atau dapat dimutasi.

## Compatibility dan Forward Fix

- signature lama `save_sales_return_draft(...)` tetap tersedia dan default
  tidak merefund ongkir;
- snapshot Return POSTED lama tetap bernilai ongkir nol dan tidak ditulis ulang;
- Draft Delivery Return existing harus ditutup sebelum migration;
- setelah migration berhasil, jangan rollback dengan menghapus kolom/history.
  Matikan entry UI bila perlu, pertahankan data, lalu gunakan forward fix.

