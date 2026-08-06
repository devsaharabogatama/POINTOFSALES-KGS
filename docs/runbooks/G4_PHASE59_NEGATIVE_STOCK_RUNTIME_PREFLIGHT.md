# G4 Phase 59 — Negative Stock Runtime Preflight

## Tujuan

Mengaudit kesiapan runtime STK-006 setelah fondasi Phase 58 lulus. File ini
tetap SELECT-only dan tidak mengaktifkan entitlement, policy, Gudang, permission,
atau checkout stok minus.

Audit memeriksa:

- rantai konfigurasi Company → policy → Gudang → user;
- masa berlaku dan tenant permission;
- sumber provisional HPP (`last FIFO` lalu fallback Product COGS);
- reconciliation Stock–FIFO–Movement sebelum invariant diubah;
- constraint snapshot Movement yang saat ini masih menolak saldo negatif;
- gap authorization/allocation pada canonical online Sale;
- kebutuhan private resolver dan replenishment reconciliation;
- Offline/import tetap tidak dapat memakai jalur stok minus;
- direct browser mutation tetap tertutup;
- dependency G5 replenishment dan G6 cost-variance tetap eksplisit.

## Menjalankan

Jalankan seluruh file berikut di Supabase SQL Editor:

`supabase/diagnostics/g4_phase59_negative_stock_runtime_preflight.sql`

Kirim semua baris hasil, termasuk `INFO`, `SETUP`, `REVIEW`, dan `DEFERRED`.

Expected sebelum foundation runtime:

- `canonical_online_negative_stock_runtime_state`: `SETUP`;
- `negative_movement_snapshot_guard_state`: `SETUP`;
- `required_private_negative_stock_routines`: `SETUP`;
- `cross_gate_replenishment_and_finance`: `DEFERRED`.

`BLOCKER` harus nol. `REVIEW` hanya dapat diterima bila berasal dari konfigurasi
yang sengaja sudah dinyalakan untuk persiapan tetapi belum digunakan; selain itu
harus dibersihkan sebelum runtime dibangun.

## Boundary

Phase berikutnya tidak boleh sekadar menghapus guard stok. Runtime wajib atomic,
online-only, non-Bundle, source-linked, reasoned, limit-aware, idempotent, dan
menulis provisional allocation. Fitur operasional tetap OFF sampai jalur
replenishment mampu menutup outstanding shortage secara deterministik.

