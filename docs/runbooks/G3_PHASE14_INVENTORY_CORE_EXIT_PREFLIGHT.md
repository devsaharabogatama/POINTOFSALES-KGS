# G3 Phase 14 — Inventory Core Exit/Stress Readiness Preflight

## Tujuan

Audit ini menentukan apakah inventory core G3 siap masuk behavioral stress
test tanpa mengklaim bahwa transaksi lintas gate sudah tersedia.

Requirement utama:

- `STK-001`: saldo Base UOM per Product–Gudang tidak negatif;
- `STK-002`: seluruh perubahan saldo memiliki immutable Movement dan source;
- `STK-003`: Opening Stock memakai dokumen khusus;
- `STK-004`: Opname mem-posting selisih melalui Adjustment;
- `STK-005`: FIFO core dan valuation konsisten;
- `STK-006`: Bundle virtual, non-nested, dan memakai komponen Product stok.

## Boundary

File berikut hanya `SELECT`:

`supabase/diagnostics/g3_phase14_inventory_core_exit_preflight.sql`

Audit mencakup:

- migration dan guarded RPC inventory G3;
- rekonsiliasi `product_stocks` terhadap agregat Movement;
- rekonsiliasi saldo terhadap remaining FIFO;
- snapshot saldo Movement terakhir;
- shape FIFO, source uniqueness, dan source-document coverage;
- link Opname → Adjustment;
- invariant Bundle virtual dan komponen;
- browser direct-write closure;
- ketersediaan fixture untuk stress test.

`Sale`, Bundle deduction pada checkout, Sales Return, Goods Receipt, dan
Purchase Return dilaporkan `DEFERRED`. Itu bukan PASS palsu dan bukan blocker
inventory core karena execution path tersebut baru sah dibuka pada G4/G5.

## Cara Menjalankan

1. Buka Supabase SQL Editor.
2. Jalankan seluruh
   `supabase/diagnostics/g3_phase14_inventory_core_exit_preflight.sql`.
3. Kirim semua row `check_name,status,details`.

## Interpretasi

- `BLOCKER`: hentikan; perbaiki invariant/data/schema sebelum stress test.
- `SETUP`: invariant aman tetapi fixture belum cukup. Buat data melalui UI/RPC
  resmi, bukan direct table write.
- `PASS`: core invariant siap.
- `DEFERRED`: coverage lintas gate yang sengaja belum dibuka.
- `INFO`: inventory runtime untuk menentukan skenario stress.

Expected normal:

- seluruh check core berstatus `PASS`;
- `stress_fixture_readiness` boleh `SETUP`;
- `cross_gate_transaction_stock_coverage` wajib `DEFERRED`;
- tidak ada direct browser write.

## Hasil Live 2026-07-28

User menjalankan seluruh diagnostic dan mengonfirmasi:

- seluruh invariant inventory core `PASS`;
- 18 guarded RPC yang diwajibkan tersedia;
- dua saldo/FIFO pair dan tiga Movement live tetap konsisten;
- satu Opening dan satu Transfer posted memiliki coverage Movement;
- belum ada Bundle aktif, Opname posted, atau Adjustment posted;
- `stress_fixture_readiness = SETUP` karena belum ada pasangan FIFO multi-layer
  dan Bundle aktif;
- coverage transaksi G4/G5 tetap `DEFERRED` sesuai desain.

Tidak ada blocker atau kebutuhan backfill live. Fixture yang kurang tidak
dibuat pada data bisnis; Phase 15 memakai fixture rollback-safe sendiri.

## Next Gate

Live gate ini sudah lulus. Jalankan
`supabase/tests/g3_phase15_inventory_core_stress_behavior_tests.sql`, lalu
rerun diagnostic ini dan G1 security closure. Jangan memasukkan
checkout/Sale/Return/Receipt ke suite G3 core.

Tidak ada migration atau rollback database pada fase SELECT-only ini.
