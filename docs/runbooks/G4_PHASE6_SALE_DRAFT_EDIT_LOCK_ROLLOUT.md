# G4 Phase 6 — Sale Draft List dan Edit-Lock Rollout

## Outcome

Foundation ini menambah nomor Draft ramah user, label/catatan, creator session,
same-Store visibility, single-editor lock dengan heartbeat lima menit,
confirmed stale takeover, Manager/Admin force release, cancel, serta audit.

Draft tetap tidak mereservasi stok dan tidak membuat Payment final, Movement,
Financial Event, atau jurnal.

## Urutan Supabase

Jalankan:

1. `supabase/migrations/20260729120000_g4_phase6_sale_draft_edit_lock.sql`;
2. `supabase/diagnostics/g4_phase6_sale_draft_edit_lock_postflight.sql`;
3. `supabase/tests/g4_phase6_sale_draft_edit_lock_tests.sql`.

Expected:

- seluruh postflight `PASS`;
- behavior notice:
  `TEST PASSED: Draft list, heartbeat, confirmed stale takeover, cancel, audit, and no-final-effect contract are enforced.`

Lalu regression:

1. `supabase/tests/g4_phase5_cashier_pricelist_override_tests.sql`;
2. `supabase/tests/g4_phase4_atomic_sale_runtime_tests.sql`;
3. `supabase/tests/g4_phase5_store_manager_pos_access_tests.sql`;
4. `supabase/tests/g1_security_closure_tests.sql`.

## Compatibility

- signature public `save_pos_sale_draft(jsonb)` dan
  `post_pos_sale(uuid,bigint,uuid)` tetap tersedia;
- implementation lama dipindahkan menjadi private core dan hanya wrapper baru
  yang dapat memanggilnya;
- Draft baru otomatis memperoleh lock pembuat sehingga client online lama tetap
  dapat Save lalu Post;
- edit Draft existing tanpa lock aktif ditolak;
- Pricelist wrapper Phase 5 tetap melewati public guarded Save/Post.

## Boundary

Migration ini belum menambahkan PWA daftar/continue/takeover Draft dan belum
membuka split payment. UI dibuat setelah database, behavior, dan regression
di atas lulus.

Migration applied tidak boleh diedit. Masalah setelah rollout harus diselesaikan
dengan forward migration.
