# Backoffice AR Reversal Helper Source Normalization Rollout

## Scope

Compatibility-only migration `20261110150000` normalizes the exact Task 5
`private.ar5_item_allocated(uuid,uuid,date)` stored source from the proven
mixed LF/CRLF representation to canonical LF. Its normalized definition,
owner, ACL, runtime configuration and routine attributes already equal the
repository contract. It changes no allocation semantics or business data.

## Mandatory manual order

Do not use an automatic sorted migration runner. Stop at the first error,
`FAIL`, or `BLOCKER`.

1. Run
   `supabase/diagnostics/backoffice_ar_reversal_helper_source_normalization_preflight.sql`.
2. Only if all mandatory rows PASS and state is `NOT_INSTALLED`, run
   `supabase/migrations/20261110150000_backoffice_ar_reversal_helper_source_normalization.sql`.
3. Run
   `supabase/diagnostics/backoffice_ar_reversal_helper_source_normalization_postflight.sql`.
4. Run
   `supabase/tests/backoffice_ar_reversal_helper_source_normalization_behavior.sql`.
5. Run Task 5 regression
   `supabase/tests/backoffice_ar_open_credit_actions_behavior.sql`; parity is
   still absent, so it must PASS with `parityConsumerAssertions:false`.
6. Run Task 6 regression
   `supabase/tests/backoffice_ar_credit_note_replacement_behavior.sql`.
7. Repeat the helper normalization postflight, Task 5 postflight and Task 6
   postflight.
8. Rerun
   `supabase/diagnostics/backoffice_ar_reversal_consumer_parity_preflight.sql`.
9. Only after its mandatory rows PASS may migration `20261110130000` be
   considered.

## Expected preflight

- Task 5, Task 6 and source bridge ledgers exactly one.
- Parity and helper-normalization ledgers zero.
- Raw helper digest may be the proven mixed digest
  `63d4690aa26036ab394907255d121a42` or canonical LF.
- Normalized helper digest exactly `3de3fd3ba6aa98e79db22ef32f1bd0da`.
- Owner `postgres`, SECURITY DEFINER, STABLE, service-role-only execution,
  expected config/ACL, and idle Finance/Offline boundaries.

## Failure and forward-fix

Do not alter immutable Task 5, Task 6, bridge or parity migration files. Do not
delete ledger rows or accept an unknown digest. The compatibility migration is
atomic. After installation, any correction requires another forward migration.
Client deployment, Production smoke and UAT remain separate gates.
