# G5 Phase 4 — Goods Receipt Readiness Preflight

Tujuan fase ini hanya memetakan kesiapan Goods Receipt canonical setelah alur
Stock Request → Supplier Order lolos smoke. Tidak ada schema atau data yang
diubah dan belum ada penerimaan yang dapat diposting.

## Jalankan

1. Selesaikan smoke UI Request → Order lebih dahulu.
2. Buka SQL Editor Supabase.
3. Jalankan seluruh
   `supabase/diagnostics/g5_phase4_goods_receipt_preflight.sql`.
4. Kirim seluruh output `check_name,status,details`.

## Interpretasi

- `BLOCKER` harus nol sebelum foundation Goods Receipt dibuat.
- `REVIEW` harus dijelaskan; Gudang `DAMAGED` boleh menjadi konfigurasi yang
  perlu disiapkan bila kondisi rusak ingin dipakai.
- `SETUP` untuk table/RPC/lineage Goods Receipt adalah expected baseline.
- `INFO` hanya inventory dan bukan kegagalan.

Preflight ini tidak mengaktifkan AP/jurnal. Foundation berikutnya harus menjaga
posting atomic/idempotent, hanya accepted quantity masuk stock/FIFO, rejected
tidak masuk stok, damaged masuk Gudang `DAMAGED`, dan replenishment Stock Minus
direkonsiliasi sebelum sisa receipt membentuk FIFO baru.
