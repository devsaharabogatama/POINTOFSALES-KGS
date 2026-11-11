# Backoffice AR Function Source Normalization Impact Audit

**Date:** 2026-11-10  
**Classification:** `SCHEMA_OR_MIGRATION_CHANGE` (`PRECONDITION CHANGE`)  
**Production mutation before this audit:** none from Task 6; its guard failed closed

## Expected outcome and source of truth

Production Task 5 and repository/local Task 5 must expose identical behavior for
`public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)`. Task 6
must not reject a semantically identical function merely because SQL transport
stored its PL/pgSQL body with CRLF instead of LF.

Defining source:
`supabase/migrations/20261106100000_backoffice_ar_open_credit_actions.sql`.
The function is consumed by the Finance open-credit action API and by Task 6's
combined Credit Note/replacement operation.

## Proven state and identifiers

- Production Task 5 ledger is present because the Task 6 dependency guard
  passed.
- Production Task 6 ledger is exactly zero after the failed attempt.
- Four other Task 6 anchors match repository/local exactly.
- Production raw Apply digest is `e89f2602af7757f99ea4b52c822162d6`.
- Production body contains 66 CRLF boundaries. Replacing CRLF with LF produces
  digest `1f3eb44dda2997282789da828e31fa81`, exactly matching repository/local.
- Owner `postgres`, `SECURITY DEFINER`, runtime configuration, signature and ACL
  match the Task 5 contract.

State classification: Task 5 `INSTALLED_CONSISTENT`; normalization bridge
`NOT_INSTALLED`; Task 6 `NOT_INSTALLED`.

## Active execution path and consumers

1. `CustomerReceiptView.tsx` calls `/api/finance/ar-open-credit-actions`.
2. The route calls `public.apply_backoffice_ar_open_credit(...)`.
3. The function writes append-only `ar_open_item_operations` and
   `ar_open_item_allocations` with tenant/customer, residual, retry and stale
   guards.
4. Task 6 calls the same function after posting a native Credit Note and before
   creating the replacement Invoice Draft.
5. AR Aging, Receipt workspace, payment context, schedule/revision consumers
   read the resulting allocations through the Task 4/5 helpers.

## Impact map

### Direct impact

- Replace only the stored function source with `pg_get_functiondef` after
  CRLF-to-LF normalization.
- Preserve function signature, owner, ACL, security-definer flag, volatility,
  parallel/leakproof attributes and runtime configuration.
- Record one compatibility migration ledger row.

### Downstream impact

- Task 6 raw digest guard becomes deterministic and can run unchanged.
- Apply/Refund/Convert/Customer Balance behavior, operation/allocation rows and
  all Finance consumers retain the same semantics.

### Explicitly preserved

- no Customer, Invoice, Credit Note, Receipt, allocation, operation, Event,
  Journal, balance, Stock, Reservation, FIFO/HPP or audit-row rewrite;
- POS Retail, retained-Retail, Backoffice posting and historical documents;
- permissions, tenant/customer isolation, idempotency, stale residual,
  concurrency lock and exact retry behavior.

### Regression risk

- DDL replacement could accidentally alter routine attributes or privileges.
  Migration snapshots and compares them before commit.
- A genuinely different definition must not be normalized. Migration requires
  the normalized digest to equal the exact Task 5 source digest.
- Active Finance/offline work is fail-closed.

## Concurrency, retry and recovery

- Migration uses a transaction-scoped advisory lock and exact ledger guard.
- Retry after commit is rejected by the ledger; failure rolls back definition
  and ledger atomically.
- No destructive rollback is planned. Any later correction is a forward fix.

## Test matrix

| Case | Expected |
|---|---|
| Production CRLF source | normalized exact digest, attributes unchanged |
| Local LF source | no semantic/definition change, ledger recorded |
| normalized digest differs | migration fails before DDL |
| active Finance/offline runtime | migration fails closed |
| exact migration retry | rejected |
| Task 5 behavior | allocation/retry/reversal suite remains PASS |
| Task 6 | unchanged migration preflight then migration/postflight/behavior |
| Stock/POS/Journals | zero effect from normalization |

## Rollout boundary

The bridge uses version `20261110140000`, the next legal version after the
locally installed `20261110130000`. On Production it is intentionally executed
before the still-pending `20261110100000`; this is a documented compatibility
prerequisite, not a replacement for Task 6. Task 6 and parity remain frozen
until bridge preflight, migration, first/closing postflight and Task 5 behavior
all pass.

