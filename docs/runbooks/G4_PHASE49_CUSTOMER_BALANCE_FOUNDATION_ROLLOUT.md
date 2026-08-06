# G4 Phase 49 — Customer Balance Foundation Rollout

## Outcome

Phase ini menambahkan policy lifecycle per Company, metode pembayaran internal
`Saldo Customer`, ledger append-only, workflow koreksi maker-checker, statement
read-only, audit, idempotency, serta Financial Event `HOLD`.

Phase ini **tidak** membuka pemakaian saldo pada checkout, credit dari
overpayment/refund/Ketul, exceptional settlement, offline Customer Balance,
atau jurnal G6. Canonical Sale harus tetap menolak `CUSTOMER_BALANCE`.

## Live preflight yang diterima

User melaporkan Phase-48 tidak mempunyai blocker/error dan hanya satu scope
backfill Company. Berdasarkan nama check Phase-48, backfill tersebut adalah
provisioning metode internal per Company. Migration tetap mempunyai hard guard:
saldo nonzero atau histori payment Customer Balance baru akan menghentikan
rollout dan wajib didesain sebagai backfill eksplisit.

## Urutan eksekusi wajib

Jalankan file penuh satu per satu di Supabase SQL Editor:

1. `supabase/migrations/20260805090000_g4_phase49_customer_balance_foundation.sql`
2. `supabase/migrations/20260805100000_g4_phase49_customer_balance_digest_fix.sql`
3. `supabase/diagnostics/g4_phase49_customer_balance_digest_fix_postflight.sql`
4. `supabase/diagnostics/g4_phase49_customer_balance_postflight.sql`
5. `supabase/tests/g4_phase49_customer_balance_foundation_tests.sql`
6. regression berikut:
   - `supabase/tests/g4_phase46_deposit_variance_resolution_tests.sql`
   - `supabase/tests/g4_phase43_cash_deposit_foundation_tests.sql`
   - `supabase/tests/g4_phase4_atomic_sale_runtime_tests.sql`
   - `supabase/tests/g1_security_closure_tests.sql`
7. rerun `supabase/diagnostics/g4_phase49_customer_balance_postflight.sql`

Jangan rerun migration bila ledger sudah berisi version terkait. Untuk database
yang sudah mempunyai `20260805090000`, mulai dari forward fix `20260805100000`.

## Expected result

- seluruh row postflight berstatus `PASS`, kecuali inventory berstatus `INFO`;
- behavioral test menampilkan notice `TEST PASSED` lalu seluruh fixture rollback;
- tepat satu policy dan satu metode internal Customer Balance tersedia per
  Company;
- Company yang entitlement-nya belum aktif tetap `DISABLED`, dengan metode
  internal inactive;
- direct INSERT/UPDATE/DELETE browser pada policy/request/ledger/audit tetap
  ditutup;
- request tidak mengubah saldo; approval reviewer berbeda membuat satu ledger,
  satu event `HOLD`, dan satu perubahan cache saldo;
- disable dengan liability masuk `WIND_DOWN`; setelah liability nol menjadi
  `DISABLED` otomatis;
- canonical checkout tetap fail-closed untuk `CUSTOMER_BALANCE`.

## Jika gagal

- Seluruh migration transactional. Error sebelum `COMMIT` berarti schema dan
  provisioning rollback; perbaiki file lalu rerun seluruh migration.
- `G4_PHASE49_STATE_CHANGED` berarti ada saldo/payment history yang tidak ada
  pada preflight. Stop—jangan set `current_balance=0` dan jangan membuat ledger
  palsu.
- `CUSTOMER_BALANCE_ACCOUNT_NOT_RESOLVED:*` pada behavioral test berarti COA
  minimum/fallback Company tidak lengkap; perbaiki foundation Finance yang
  relevan, bukan bypass resolver.
- `TEST_PRECONDITION_FAILED: two linked users required` berarti environment
  belum mempunyai dua user untuk menguji maker-checker. Tambahkan user test
  kedua, lalu rerun test; migration tidak perlu diulang.
- Bila satu postflight `FAIL`, kirim seluruh output sebelum melanjutkan UI atau
  membuka checkout usage.

## Compatibility dan rollback boundary

- `customers.current_balance` tetap kolom cache legacy, tetapi hanya guarded
  workflow baru yang boleh mengubahnya pada scope Customer Balance.
- Method `CUSTOMER_BALANCE` adalah system-owned dan tidak dapat dibuat lewat
  generic Payment Method form.
- History ledger/audit immutable dan tidak boleh dihapus untuk rollback.
- Setelah live data tercipta, rollback dilakukan dengan forward-fix; jangan
  drop table atau mengedit migration applied.

## Next safe step

Setelah migration, postflight, behavioral, regression, dan closing postflight
seluruhnya dikonfirmasi user PASS, lanjut ke UI operasional request/review dan
statement Customer Balance. Checkout usage tetap fase terpisah setelah UI dan
invariant ledger tervalidasi.
