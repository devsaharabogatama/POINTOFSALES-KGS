# G4 Phase 14 — Offline Catalog Snapshot Rollout

## Tujuan

Menambahkan satu RPC browser-scoped yang menghasilkan snapshot katalog Offline
untuk satu Cashier Session yang masih `OPEN`. Snapshot bersifat authoritative
terhadap Company, Store, Terminal, Gudang penjualan, Product-UOM, Pricelist,
Sales Tax, Payment Method, dan Stock Allowance pada waktu snapshot.

Rollout ini **tidak**:

- mengaktifkan feature `offline_pos_enabled`;
- membuat Terminal eligible secara otomatis;
- menghubungkan Keranjang PWA ke jalur checkout Offline;
- mengubah resolver harga/Tax online;
- membuka direct write tabel kepada browser.

## Evidence Preflight Live

Output user 30 Juli 2026:

- dependency Phase 12 dan seluruh invariant data `PASS`;
- browser direct-write dan RPC boundary `PASS`;
- entitlement Offline tetap disabled;
- tidak ada submission nonterminal;
- satu open Session memiliki Cash, tetapi belum memiliki Terminal policy;
- snapshot RPC belum ada dan tepat berstatus `SETUP`;
- dua Pricelist, satu Pricelist Rule, satu Sales Tax Rule, serta satu
  Product-UOM aktif harus ikut snapshot secara eksplisit.

Status tersebut aman untuk migration. Missing Terminal policy adalah
configuration gate, bukan alasan untuk membuat policy diam-diam.

## Urutan Eksekusi Manual

### 1. Jalankan migration

Jalankan seluruh file:

`supabase/migrations/20260730010000_g4_phase14_offline_catalog_snapshot.sql`

Expected: `Success. No rows returned`.

Jangan menjalankan ulang bila ledger version `20260730010000` sudah ada.

### 2. Jalankan postflight

Jalankan seluruh file:

`supabase/diagnostics/g4_phase14_offline_catalog_snapshot_postflight.sql`

Expected:

- seluruh check wajib `PASS`;
- `terminal_policy_configuration_scope` boleh `SETUP` selama Offline belum
  akan diaktifkan;
- `offline_entitlement_remains_closed` wajib `PASS`;
- baris `INFO` hanya inventory.

Hentikan bila ada `FAIL`.

### 3. Jalankan behavioral test

Jalankan seluruh file:

`supabase/tests/g4_phase14_offline_catalog_snapshot_tests.sql`

Test membutuhkan minimal satu Cashier Session `OPEN` yang terhubung ke
`auth.users`. Test mengaktifkan entitlement dan Terminal policy sementara,
memanggil RPC sebagai cashier Session tersebut, lalu memvalidasi bentuk
snapshot serta privilege boundary. Seluruh perubahan dibungkus `BEGIN` /
`ROLLBACK`; feature dan policy produksi tidak berubah.

Expected notice:

`TEST PASSED: Offline catalog snapshot is Session-scoped, authoritative, and browser-guarded.`

### 4. Regression

Jalankan ulang:

1. `supabase/tests/g4_phase12_offline_sync_tests.sql`;
2. `supabase/tests/g4_phase11_offline_stock_allowance_tests.sql`;
3. `supabase/tests/g4_phase4_atomic_sale_runtime_tests.sql`;
4. `supabase/tests/g1_security_closure_tests.sql`;
5. `supabase/diagnostics/g4_phase14_offline_catalog_snapshot_postflight.sql`.

Semua check wajib tetap `PASS`; `INFO` dan Terminal `SETUP` tidak dianggap
failure selama feature Offline tetap disabled.

## Compatibility dan Forward-Fix

- Perubahan hanya menambah function dan ledger row.
- Online checkout, Draft/Post, receipt, split payment, dan queue Phase 13 tidak
  berubah.
- Tidak ada tabel atau data bisnis yang diubah.
- Setelah migration applied, jangan edit file migration. Perbaikan dilakukan
  melalui migration forward-only berikutnya.
- Rollback darurat sebelum dipakai PWA: revoke execute lalu drop exact function
  signature melalui migration forward-fix. Ledger tidak dihapus manual.

## Gate Sesudah Rollout

Setelah migration, postflight, behavioral, dan regression dikonfirmasi sukses,
step aman berikutnya adalah cache snapshot retained di PWA. Checkout Offline
tetap tertutup sampai:

- konfigurasi Terminal dilakukan eksplisit oleh Super Admin;
- allowance Session diterbitkan server-side;
- cache, expiry, dan invalidation PWA lulus authenticated smoke;
- entitlement Offline baru diaktifkan pada Company/Store/Terminal UAT.
