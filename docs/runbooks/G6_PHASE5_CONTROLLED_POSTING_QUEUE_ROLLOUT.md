# G6 Corrective Phase 5 — Controlled Posting Queue Rollout

## Outcome

Memasang queue historis satu active Company yang mewajibkan preview dan
approval sebelum processor memanggil posting authority Phase 4. Migration tidak
membuat queue run dan tidak memproses event `HOLD` existing.

## Scope runtime

- hanya event `STOCK_OPENING` + `opening_stock_documents` yang masuk preview;
- satu Company hanya dapat mempunyai satu run berstatus
  `PREVIEWED`/`APPROVED`/`PROCESSING`;
- preview membekukan event ID, version, source, category, date, dan hash;
- approval menolak preview yang sudah stale;
- processor menggunakan `private.post_financial_event_core` Phase 4;
- kegagalan satu event rollback pada subtransaction item tersebut, disimpan
  sebagai `FAILED` + `finance_posting_exceptions`, lalu item lain dapat lanjut;
- retry/replay run final tidak menggandakan journal;
- queue/item/audit final append-only dan browser tidak mempunyai direct write;
- 25 kontrak event lain tetap `HOLD/DEFERRED`.

## Urutan manual wajib

### 1. Migration

Jalankan seluruh:

`supabase/migrations/20260810210000_g6_phase5_controlled_posting_queue.sql`

Expected: `Success. No rows returned`.

### 2. Postflight

Jalankan seluruh:

`supabase/diagnostics/g6_phase5_controlled_posting_queue_postflight.sql`

Expected: seluruh row selain inventory `INFO` berstatus `PASS` dan
`violation_rows = 0`.

### 3. Behavioral test

Jalankan seluruh:

`supabase/tests/g6_phase5_controlled_posting_queue_tests.sql`

Expected notice:

`TEST PASSED: G6 Phase 5 queue is active-Company scoped, previewed, approved, per-event isolated, idempotent, immutable, and audited.`

Semua fixture dan journal test di-rollback.

### 4. Regression minimum

1. `supabase/tests/g6_phase4_atomic_single_event_posting_tests.sql`
2. `supabase/diagnostics/g6_phase4_atomic_single_event_posting_postflight.sql`
3. `supabase/tests/g6_phase3_versioned_posting_mapping_tests.sql`
4. `supabase/tests/g6_phase2_tenant_safe_journal_tests.sql`
5. `supabase/tests/g1_security_closure_tests.sql`
6. rerun postflight Phase 5.

## Jangan proses historical event live dulu

Behavioral test hanya memakai Company sintetis dan rollback. Jangan memanggil
RPC preview/approve/process untuk satu event live yang ditemukan preflight pada
rollout schema ini. Controlled live backfill baru dilakukan setelah seluruh
database gate di atas PASS dan output closing diagnostic direview. Tidak ada
alasan untuk memproses 25 event unsupported.

## Forward-fix / rollback

Migration additive dan transactional. Jika migration gagal sebelum `COMMIT`,
seluruh object rollback otomatis dan file yang sama dapat dijalankan ulang
setelah penyebab diperbaiki.

Setelah ledger `20260810210000` tercatat, jangan drop/edit migration atau
mengubah event `POSTED` kembali ke `HOLD`. Perbaikan wajib migration baru yang
forward-only. Queue history dan canonical journal tidak boleh dihapus.

## Compatibility

- RPC single-event Phase 4 tetap tersedia dan tidak diubah;
- historical HOLD tidak berubah saat migration;
- journal existing tetap immutable;
- report Finance belum dibuka;
- Backoffice queue UI tetap Phase 7, bukan bagian rollout ini.
