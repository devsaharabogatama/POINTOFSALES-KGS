# POS Scheduled Draft Resume Forward-fix

**Status:** production migration, behavioral test, and postflight user-confirmed
PASS on 2026-09-10; authenticated POS smoke remains operational verification.

**Target:** production Supabase after read-only preflight is clean.

**Scope:** future Scheduled TEMPO Draft save/reprice on `Lanjutkan`.
**No backfill:** existing Draft remains unchanged.

## Root cause

`Lanjutkan` performs a canonical reprice save. A future Scheduled Draft sends
its preserved planned timestamp into the ordinary TEMPO effective-date
validator, which correctly rejects future effective dates but is the wrong
validator for a Draft that is already canonical `SCHEDULED`.

The fix does not weaken that validator. It adds a narrow routing helper:

- `SCHEDULED + TEMPO + PRESERVE + planned date still future` uses Scheduled
  due/delivery and date-identity validation;
- all other TEMPO saves continue through the existing effective-date and
  accounting-period validator;
- `post_pos_sale` remains unchanged and still rejects posting before the
  planned date.

The existing Draft snapshot is read first without adding a row lock. The
unchanged canonical save chain still owns lock ordering and optimistic
`masterVersion` enforcement, so a concurrent change fails stale instead of
overwriting it. The preserved timestamp comes from the existing server snapshot,
not from a browser-supplied replacement value; Company/date identity is checked
again before Scheduled metadata is restored after repricing.

## Manual rollout

Database rollout steps 1-5 were confirmed successful by the user on
2026-09-10. Step 6 remains the final authenticated UI smoke.

1. Run [preflight](../../supabase/diagnostics/pos_scheduled_draft_resume_preflight.sql).
2. `SETUP` on `scheduled_resume_definition_before_fix` is expected. Stop on
   `BLOCKER` or SQL error.
3. Run [migration](../../supabase/migrations/20260910100000_pos_scheduled_draft_resume_fix.sql).
4. Run [behavioral test](../../supabase/tests/pos_scheduled_draft_resume_behavior.sql).
5. Run [postflight](../../supabase/diagnostics/pos_scheduled_draft_resume_postflight.sql).
6. Authenticated smoke in LSM: open `DRF-20260910-000378`, click `Lanjutkan`,
   verify the Draft opens and still shows planned Order date 11 September 2026.
7. Do not confirm/post it before the planned business date; verify early Post
   remains blocked.

## Compatibility and rollback

- No Order, Revision, Reservation, Stock/FIFO, Invoice/SJ, Payment, Finance, or
  Accounting Period row is backfilled by the migration.
- Existing immediate/backorder save and Scheduled creation behavior remain on
  their old paths.
- Before authenticated smoke, rollback can restore the previous private wrapper
  definition and drop the helper. After runtime use, prefer a forward-fix; never
  delete or rewrite operational Draft history.
