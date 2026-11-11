# Backoffice AR Task 5 UAT Fixture Selection Audit

Date: 2026-11-10  
Classification: `TEST_HARNESS_ONLY` / `FIXTURE FIX`  
Target: local Docker only; Production unchanged.

## Failure evidence

`backoffice_ar_open_credit_actions_behavior.sql` stopped at
`FIXTURE_OPEN_CREDIT` with `rollback fixture could not expose residual >= 10`.
The active product assertion was not changed or bypassed.

The selector accepted the first Posted native Backoffice Credit Note with an
original amount of at least 10. Local browser UAT had already fully settled its
source Invoice with independent Receipt allocations. Reversing allocations
owned by the Credit Note therefore restored Credit Note residual but could not
restore source-Invoice residual.

## Active path and identifiers

- Candidate registry: `public.ar_open_item_registry`.
- Effective allocation authority:
  `private.ar5_item_allocated(uuid,uuid,date)` from migration `20261106100000`.
- Pair lineage: `public.ar_open_item_allocations.debit_item_id`,
  `credit_item_id`, and `reversal_of_allocation_id`.
- Product functions and assertions under test remain unchanged.

## Fix boundary

The historical candidate is eligible only when the current source-Invoice
residual plus the effective allocation from that exact Credit Note to that
exact Invoice can expose at least 10 after the rollback fixture reverses it.
Otherwise the existing canonical local rollback fixture must be used.

This change does not alter Product code, schema, migration, Finance data, or
expected values. It prevents unrelated Receipt settlement from making a
historical candidate look usable.

## Regression requirement

Rerun the full Task 5 behavior. It must still cover exact/changed retry,
stale residual, cross-Customer/Company denial, convert/use balance, refund and
reversal Journals, zero Retail/Stock/FIFO effect, and rollback of every fixture
write. Task 6 runs only after Task 5 passes.
