# G4 Phase 5 — Store Manager POS Access Forward Fix

## Status

`READY FOR MANUAL SUPABASE ROLLOUT`

## Root Cause

Store Manager sudah mempunyai Company dan Store membership aktif, tetapi PWA
dan `open_cashier_session(...)` hanya menganggap Store role `CASHIER` sebagai
operator POS. Ini bertentangan dengan matrix approved: Store Manager boleh
checkout ketika menggunakan POS.

Forward fix ini menambahkan `STORE_MANAGER` sebagai operator hanya pada Store
assignment aktifnya. Super/Admin inheritance dan Cashier Store scope tetap
dipertahankan.

## Urutan Manual

Jika `20260729080000` belum dijalankan, jalankan paket role-inheritance tersebut
lebih dahulu. Setelah itu:

1. jalankan
   `supabase/migrations/20260729090000_g4_phase5_store_manager_pos_access_fix.sql`;
2. jalankan
   `supabase/diagnostics/g4_phase5_store_manager_pos_access_postflight.sql`;
3. jalankan
   `supabase/tests/g4_phase5_store_manager_pos_access_tests.sql`;
4. regression:
   - `supabase/tests/g4_phase5_cashier_role_inheritance_tests.sql`;
   - `supabase/tests/g4_phase2_cashier_session_foundation_tests.sql`;
   - `supabase/tests/g1_security_closure_tests.sql`.

Expected postflight: 4 `PASS`. Behavioral test harus menghasilkan
`TEST PASSED` dan diakhiri `ROLLBACK`.

## Smoke

1. restart PWA;
2. login sebagai Store Manager yang memiliki assignment Store aktif;
3. Terminal hanya dari Store tersebut harus tampil;
4. Gudang hanya tampil bila `is_sale_source = true` dan terkait Store Terminal
   atau Company-wide;
5. Terminal Store lain tidak boleh terlihat/dapat dibuka;
6. buka Session lalu lanjutkan canonical Draft/Post smoke.

## Compatibility dan Security

- tidak ada perubahan schema/data/backfill;
- ordinary Cashier tetap memerlukan assignment `CASHIER`;
- Store Manager tidak memperoleh akses lintas Store;
- active Company, Terminal, Gudang sale-source, one-open Session, RLS, dan
  audit tetap ditegakkan server-side.

## Forward Fix

Jangan edit migration yang sudah applied. Jika predicate perlu dikoreksi lagi,
hentikan pembukaan Session baru dan buat migration forward tambahan.
