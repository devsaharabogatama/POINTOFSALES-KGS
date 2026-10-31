# POS Retail Non-Cash Atomic Verification Rollout

## Outcome

For direct Retail POS payments using `DIRECT_BANK` or `CLEARING`, Finance
verification and payment-journal posting become one atomic action. Cash remains
automatic. Later Tempo collections remain in **Penerimaan Customer**.

## Status layers

- Audit: complete.
- Local UI/API code: focused lint, UI contract, and Backoffice build passed.
- Local SQL rehearsal: pending because the Docker/Supabase local database is
  unavailable.
- Database live: not yet; migration must be run manually.
- Client deployed: not yet.
- Authenticated smoke: not yet.
- UAT: not yet.

## Manual rollout order

Before step 1, create/open the KGS accounting period covering October 2026
through the authorized Finance period workflow. SELECT-only Production evidence
on 2026-10-31 found no KGS period covering the current date; the migration is
designed to stop rather than commit an unusable verification flow.

Run each file in a fresh Supabase SQL Editor execution and stop on any
`BLOCKER`, `FAIL`, or unexpected error.

1. `supabase/diagnostics/pos_retail_non_cash_atomic_verification_preflight.sql`
2. `supabase/migrations/20261031100000_pos_retail_non_cash_atomic_verification.sql`
3. `supabase/diagnostics/pos_retail_non_cash_atomic_verification_postflight.sql`
4. `supabase/tests/pos_retail_non_cash_atomic_verification_behavior.sql`

Do not rerun the migration after its ledger row exists. Send every output back
for classification before deploying the Backoffice client.

## Expected preflight

- dependency ledger `PASS`;
- installation state `NOT_INSTALLED`;
- runtime anchors `PASS`;
- backlog partition `PASS`;
- Finance authority `PASS`, including one current open/reopened accounting
  period for every Company in scope;
- active Finance queue and nonterminal Offline submissions both zero.

The observed 2026-10-31 KGS partition was 40 missing requests: 38 safe
`HOLD/no-Journal` legs and two already-posted legacy legs. The counts may grow
before rollout, but every row must still fit one of those proven accounting
ownership states.

## Expected postflight and behavior

- the 38-style safe backlog has a request; already-posted legacy rows remain
  unchanged and request-less;
- Cash has no new manual-review rows;
- Customer Receipt reconciliation remains valid;
- behavior verifies a Bank request and posts exactly one two-line Journal in
  the same transaction;
- exact retry creates no duplicate Event/Journal;
- a same-account Clearing fixture closes as `NO_FINANCIAL_EFFECT`;
- maker-checker, stale version, and cross-Company boundaries remain enforced;
- the behavior transaction rolls back all test effects.

## Authenticated smoke after deployment

1. Create one Retail POS Transfer sale and one QRIS sale. Cash is a separate
   regression case.
2. Confirm both non-cash payments appear in Finance > Verifikasi Pembayaran.
3. Verify Transfer: the action must finish with a Posted payment Journal and no
   second queue action.
4. Verify QRIS: when source and clearing resolve to the same account, the UI
   must report no additional Journal and the Event must close no-effect.
5. Retry the same request and confirm no duplicate Journal.
6. Reject a separate pending request and confirm no payment Journal is created.
7. Confirm Cash still bypasses manual Finance verification.
8. Confirm a later Tempo invoice payment still posts through Penerimaan
   Customer.
9. Confirm Stock, FIFO, Invoice, receipt, session, Return, and Backoffice paths
   have no duplicate effect.

## Rollback / forward-fix

The migration is transactional: an installation failure rolls back completely.
After a successful rollout, do not delete its ledger row, trigger, requests,
Events, or Journals and do not edit this migration. Any defect requires a new
guarded forward migration. Existing Posted Journals are immutable.
