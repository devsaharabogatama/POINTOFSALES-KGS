# G3 Phase 4 — Canonical Stock Movement Rollout

## Status

`COMPLETE — POSTFLIGHT, BEHAVIORAL, DAN REGRESSION PASS`

Dependency preflight telah dikonfirmasi user:

- seluruh invariant `PASS`;
- satu Opening movement dan satu Product–Gudang pair;
- saldo sama dengan agregasi movement;
- tidak ada duplicate/orphan/negative balance;
- browser write seluruhnya `false`;
- delapan canonical snapshot column dan lima future enum memang belum ada.

## Urutan eksekusi

1. Jalankan migration:
   `supabase/migrations/20260728150000_g3_phase4_canonical_stock_movement.sql`
2. Jalankan postflight:
   `supabase/diagnostics/g3_phase4_canonical_stock_movement_postflight.sql`
3. Pastikan seluruh postflight `PASS` dan `violation_rows = 0`.
4. Jalankan behavioral test:
   `supabase/tests/g3_phase4_canonical_stock_movement_tests.sql`
5. Jalankan regression:
   - `supabase/tests/g3_phase1_opening_stock_tests.sql`
   - `supabase/tests/g2_phase46_product_warehouse_minimum_stock_tests.sql`
   - `supabase/tests/g1_security_closure_tests.sql`

Seluruh gate di atas telah dikonfirmasi user lulus. Langkah berikutnya adalah
authenticated smoke Kartu Stok pada
`docs/runbooks/G3_PHASE5_STOCK_MOVEMENT_API_UI.md`.

## Isi migration

- delapan kolom canonical movement additive;
- deterministic backfill untuk movement Opening existing;
- snapshot completeness guard khusus `OPENING_BALANCE`;
- source-line uniqueness dan card query index;
- trigger enrichment untuk Opening movement baru;
- immutable update/delete guard;
- vocabulary enum future tanpa mengaktifkan source workflow tersebut.

## Compatibility

- signature `post_opening_stock(...)` tidak berubah;
- Product balance dan FIFO tidak dihitung ulang;
- non-Opening movement column tetap nullable sampai source workflow canonical
  masing-masing dibuka;
- legacy Transfer/Purchase/Sale tidak dinyatakan production-ready;
- browser tetap hanya mempunyai `SELECT`;
- tidak ada notification, Stock Request, Purchasing, atau journal posting.

## Forward-fix policy

Migration ini forward-only setelah applied. Jika gagal sebelum ledger insert,
transaksi rollback penuh. Jika postflight menemukan masalah setelah commit,
jangan edit file migration; buat forward fix dengan version lebih tinggi.
