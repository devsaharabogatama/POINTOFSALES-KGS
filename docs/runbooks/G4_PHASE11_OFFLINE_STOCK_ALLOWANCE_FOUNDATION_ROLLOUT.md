# G4 Phase 11 — Offline Stock Allowance Foundation Rollout

## Status dan batas fase

Migration ini membuka fondasi server-side untuk Offline Stock Allowance:

- default Company 20%;
- optional persentase override per Store;
- eligibility Terminal yang harus dipilih eksplisit;
- reservation per Session, Gudang, Product, dan Base UOM;
- guard agar mutation stok apa pun tidak memakai stok yang sudah direservasi;
- release/force revoke, audit, dan blocker penutupan Session;
- server-only submission envelope dan event history.

Fase ini **belum** membuka:

- checkout offline di PWA;
- endpoint ingest/sync;
- konsumsi allowance oleh Sale;
- posting invoice/Movement/Payment offline;
- verifikasi Payment elektronik offline;
- Offline Price Variance atau Finance exception.

Endpoint `/api/pos/sync` wajib tetap menjawab `OFFLINE_SYNC_NOT_ENABLED`.
Entitlement `offline_pos_enabled` harus tetap mati selama rollout dan test.

## Evidence preflight yang disetujui

- seluruh dependency, tenant, identity, Session, browser-write, stock, movement,
  dan FIFO invariant `PASS`;
- satu Company, Store, Terminal, POS operator, Gudang sale-source, Cash, dan
  metode elektronik siap;
- dua positive stock/FIFO pair konsisten;
- entitlement offline disabled;
- lima tabel canonical berstatus expected `SETUP`.

## File

1. `supabase/migrations/20260729180000_g4_phase11_offline_stock_allowance_foundation.sql`
2. `supabase/diagnostics/g4_phase11_offline_stock_allowance_postflight.sql`
3. `supabase/tests/g4_phase11_offline_stock_allowance_tests.sql`

## Urutan manual

### 1. Pastikan entitlement masih mati

Gunakan halaman Settings/Super Admin. Jangan mengubah
`company_features` langsung.

### 2. Jalankan migration

Jalankan seluruh migration Phase 11 satu kali di Supabase SQL Editor.
Migration transactional; error sebelum `COMMIT` menggagalkan seluruh perubahan.

Migration berhenti bila:

- dependency `20260729150000` belum ada;
- ledger Phase 11 sudah ada;
- salah satu entitlement offline sudah aktif;
- salah satu tabel target sudah ada.

### 3. Jalankan postflight

Jalankan seluruh postflight. Expected: seluruh baris `PASS` dan
`violation_rows = 0`.

`offline_foundation_inventory` tetap `PASS` walaupun allowance/submission masih
nol. Default policy Company harus tepat satu per Company aktif dengan nilai
`0.200000`.

### 4. Jalankan behavioral test

Test berjalan dalam `BEGIN/ROLLBACK` dan membuktikan:

- Company default, Store override, dan Terminal eligibility guarded;
- Cashier mendapat allowance Store 10% dari stok 10 = 1 Base UOM;
- retry mengembalikan allowance yang sama;
- stok reserved tidak dapat dikurangi;
- Session tidak dapat ditutup sebelum allowance diselesaikan;
- cross-Company Product ditolak;
- release membebaskan reservation;
- feature disabled menolak issuance;
- Manager/Admin dapat force revoke dengan alasan;
- Session dapat ditutup setelah reservation selesai;
- allowance/audit history tidak dapat dihapus atau ditulis ulang;
- audit dan browser privilege boundary benar.

### 5. Regression minimum

Jalankan berurutan:

1. `supabase/diagnostics/g4_phase10_online_checkout_stress_preflight.sql`;
2. `supabase/tests/g4_phase8_payment_leg_identity_tests.sql`;
3. `supabase/tests/g4_phase6_sale_draft_edit_lock_tests.sql`;
4. `supabase/diagnostics/g3_phase14_inventory_core_exit_preflight.sql`;
5. `supabase/tests/g1_security_closure_tests.sql`.

Jangan rerun harness Post terhadap Draft lama yang sudah `POSTED`.

## Compatibility

- Sale online tetap memakai RPC canonical yang sama.
- Allowance adalah reservation, bukan Movement dan bukan pengurangan on-hand.
- Trigger stok hanya menolak saldo baru yang lebih kecil daripada total
  reservation aktif.
- Product, FIFO, Movement, Session, Payment, dan receipt existing tidak
  dibackfill atau ditulis ulang.
- Tabel submission tidak mempunyai browser write grant dan belum mempunyai
  public ingest RPC.

## Recovery / forward-fix

Sebelum `COMMIT`, cukup perbaiki file dan rerun seluruh migration. Setelah
applied, jangan mengedit migration:

1. biarkan entitlement offline disabled;
2. jangan membuat policy Terminal pada production;
3. gunakan forward migration untuk koreksi schema/function;
4. bila allowance pernah diterbitkan, release atau force revoke melalui RPC
   guarded—jangan menghapus row atau mengubah stok langsung.

## Next safe step

Setelah migration, seluruh postflight, behavioral test, dan regression lulus,
gate berikutnya adalah Phase 12: preflight/implementation ingest queue dan
atomic sync posting. PWA offline baru dikerjakan setelah server sync tersebut
terbukti idempotent.
