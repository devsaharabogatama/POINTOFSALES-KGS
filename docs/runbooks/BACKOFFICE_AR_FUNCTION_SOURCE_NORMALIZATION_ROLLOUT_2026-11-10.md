# Backoffice AR Function Source Normalization Rollout

## Scope

Compatibility-only migration `20261110140000` normalizes the stored Task 5
Apply Credit function from CRLF to LF after proving its normalized definition
is exactly the repository source. It changes no business behavior or data.

Production Task 6 previously failed closed. Task 6 ledger remains zero and no
Task 6 schema object was created.

## Mandatory order

Do not use an automatic sorted migration runner for this recovery sequence.
Run the exact files manually in this order and stop at the first non-PASS/error:

1. `supabase/diagnostics/backoffice_ar_function_source_normalization_preflight.sql`
2. `supabase/migrations/20261110140000_backoffice_ar_function_source_normalization.sql`
3. `supabase/diagnostics/backoffice_ar_function_source_normalization_postflight.sql`
4. `supabase/tests/backoffice_ar_function_source_normalization_behavior.sql`
5. `supabase/tests/backoffice_ar_open_credit_actions_behavior.sql`. Before
   parity is installed it tests every Task 5 invariant but reports
   `parityConsumerAssertions:false`; after parity it additionally enforces the
   shared-consumer reversal assertions.
6. Repeat both normalization and Task 5 postflights.
7. `supabase/diagnostics/backoffice_ar_credit_note_replacement_preflight.sql`
8. Only when every mandatory Task 6 preflight row is PASS, run
   `supabase/migrations/20261110100000_backoffice_ar_credit_note_replacement_invoice.sql`.
9. Run Task 6 postflight, rollback-only behavior, and closing postflight.
10. Only after Task 6 closes cleanly, rerun reversal-parity preflight before
    considering `20261110130000`.

The version `20261110140000` is newer because already-installed migration
versions are immutable and the manifest forbids adding a lower version. Its
execution before the pending Task 6 is an explicit compatibility prerequisite.

## Expected normalization preflight

- Task 5 ledger exactly one.
- Task 6 ledger zero in Production.
- normalization ledger zero.
- normalized digest exactly `1f3eb44dda2997282789da828e31fa81`.
- raw digest may be Production CRLF `e89f2602af7757f99ea4b52c822162d6`
  or already-normalized LF digest.
- Finance queue and Offline nonterminal rows zero.

## Failure handling

- Any unexpected digest, missing routine, changed ACL/config/owner, active
  runtime, SQL error or FAIL freezes the rollout.
- Do not edit Task 5/6 migrations, delete ledger rows or replace expected hashes.
- The migration is atomic. Failure before commit leaves function and ledger
  unchanged.
- After successful commit, corrections use a new forward migration; do not
  restore CRLF as rollback.

## Status vocabulary

- `LOCAL READY`: yes after the evidence recorded on 2026-11-10.
- `DATABASE LIVE`: local Docker only until user returns Production evidence.
- `CLIENT DEPLOYED`: no change required by normalization.
- `SMOKE PASS` / `UAT PASS`: not implied by migration/postflight.

