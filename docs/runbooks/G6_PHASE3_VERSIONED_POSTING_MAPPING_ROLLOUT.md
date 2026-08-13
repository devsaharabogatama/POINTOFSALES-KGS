# G6 Corrective Phase 3 Versioned Posting Mapping Rollout

## Outcome

Menyediakan mapping akun required yang eksplisit serta rule-set debit/kredit
yang versioned, effective-dated, approved, immutable setelah approval, dan
audited. Phase ini tidak menjalankan formula, tidak memproses Financial Event
`HOLD`, dan tidak membuat jurnal.

## Urutan manual

Jalankan satu per satu di Supabase SQL Editor:

1. selesaikan terlebih dahulu
   `docs/runbooks/G6_PHASE3_IMPORTED_COA_OWNERSHIP_FIX.md`;
2. rerun latest
   `supabase/diagnostics/g6_phase3_versioned_posting_mapping_preflight.sql` dan
   pastikan `explicit_system_function_account_scope=PASS`;
3. `supabase/migrations/20260810190000_g6_phase3_versioned_posting_mapping.sql`
4. `supabase/diagnostics/g6_phase3_versioned_posting_mapping_postflight.sql`
5. `supabase/tests/g6_phase3_versioned_posting_mapping_tests.sql`
6. rerun
   `supabase/diagnostics/g6_phase3_versioned_posting_mapping_preflight.sql`

Hentikan bila satu langkah error. Kirim seluruh output postflight dan hasil
behavioral test sebelum Phase 4 dibuat.

## Expected

- postflight seluruh row selain inventory berstatus `PASS`;
- `required_account_mapping_coverage` nol violation;
- mapping required hanya menunjuk akun yang
  `chart_of_accounts.system_function_key` sama persis;
- behavioral test menghasilkan notice `TEST PASSED` lalu rollback;
- rerun preflight mengubah dua mapping `BACKFILL` menjadi `PASS` dan expression
  model menjadi `PASS`;
- `hold_event_rule_snapshot_state=SETUP` tetap expected karena snapshot hanya
  boleh ditulis oleh posting engine Phase 4/controlled backfill Phase 5;
- jumlah canonical journal tetap nol dan seluruh 26 event lama tetap `HOLD`.

## Kontrak keamanan

- Provisioning akun tidak memakai account type sebagai pemilih. Account type
  hanya validation. Resolver memilih tepat satu akun active/postable bertanda
  `is_system_account=true` dengan `system_function_key` identik; bila akun
  sistem tidak ada, tepat satu akun explicit non-system boleh menjadi fallback.
- Bila terdapat lebih dari satu akun sistem kanonis, atau tidak tersedia sole
  explicit fallback, migration rollback penuh dengan
  `PHASE3_REQUIRED_MAPPING_UNRESOLVED`.
- Browser hanya SELECT sesuai active Company/role Finance. Mutation melalui
  `save_posting_rule_set` dan `approve_posting_rule_set`.
- Rule-set approved dan seluruh line-nya immutable. Versi baru memakai row baru
  serta menutup effective period versi sebelumnya.
- Expression key pada Phase 3 adalah identifier declarative, bukan SQL dan
  belum dieksekusi. Whitelist resolver source-event dibangun Phase 4.

## Compatibility dan rollback

- `transaction_account_rules` dipertahankan sebagai canonical account resolver;
- existing rule/fallback tidak dihapus atau ditimpa;
- `financial_events`, journal legacy, dan journal canonical tidak dimutasi;
- jika migration gagal, transaction melakukan rollback penuh;
- setelah applied, jangan drop tabel/rule historis. Koreksi dilakukan melalui
  forward migration karena mapping approved adalah audit history.

## Next safe step

Setelah empat gate dikonfirmasi PASS, lanjut Corrective Phase 4: resolver
source-event ber-whitelist dan atomic single-event posting. Jangan menjalankan
queue/backfill 26 event HOLD sebelum Phase 5.
