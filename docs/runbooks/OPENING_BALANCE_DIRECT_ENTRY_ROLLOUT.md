# Opening Balance direct-entry rollout

## Status

`LOCAL PACKAGE`; not installed or deployed by the agent.

## Order

0. Staging compile requires the staging project's downloaded CA certificate at
   `%TEMP%\mads-invoice-staging-20261005\supabase-root-ca.crt`. Do not disable
   certificate verification as a workaround.
1. Run `supabase/diagnostics/opening_balance_direct_entry_preflight.sql` on the
   target database. Every non-INFO row must be PASS.
2. Review the immutable migration checksum and execute
   `supabase/migrations/20261029100000_opening_balance_direct_entry.sql` once.
3. Run `supabase/tests/opening_balance_direct_entry_behavior.sql` as the
   rollback-only behavior test. It must create a representative Draft,
   reject invalid control-account usage/cross-Company references, submit/post
   with a different approver, prove one balanced journal and roll everything
   back.
4. Run `supabase/diagnostics/opening_balance_direct_entry_postflight.sql`.
5. Deploy the matching Backoffice commit only after database behavior and
   postflight pass.
6. Authenticated smoke: Finance creates/saves/submits; Company Admin approves;
   Trial Balance/GL show the journal; other Company cannot read it.

## KGFF entry sequence

Cutover authority: Opening Stock and Finance Opening Balance are effective
`2026-10-31`; KGFF operational transactions start `2026-11-01`.

1. Create/open the accounting period containing `2026-10-31`.
2. Post Inventory > Stok Awal first. Selecting a Product pre-fills HPP from
   the Product master; review/correct it before saving. Do not duplicate
   Inventory in Finance.
3. Open Finance > Jurnal Keuangan > Saldo Awal.
4. Add non-inventory GL balances. Use Piutang Customer and Utang Supplier row
   types for AR/AP; enter one aggregate balance per Customer/Supplier. Do not
   recreate historical invoice numbers, dates, due dates, or transactions.
5. Use Opening Balance Clearing to offset the separate Opening Stock journal so
   the final clearing balance is zero.
6. Save Draft, review totals, submit, and have a different authorized Company
   Admin/Super Admin approve and post.
7. Reconcile Trial Balance, Inventory/FIFO, AR detail, AP detail, cash/bank and
   Opening Balance Clearing before live transactions.

## Important boundary

This migration establishes opening GL and party-level open-item records. It
does not yet widen existing Customer Receipt/Supplier Payment allocation
foreign keys. Do not mark operational AR/AP collection smoke complete until the
separate payment-consumer extension is installed and tested.

Do not execute the Production migration while the status remains `LOCAL
PACKAGE`. The staging schema compile and rollback-only database behavior are
mandatory first gates.

## Rollback / correction

- Before installation: do not run the migration.
- After installation: never remove the ledger or rerun/edit the migration.
- Draft/Submitted documents may be canceled.
- Posted opening balances use the canonical reversal/replacement workflow.
- Runtime/schema defects require a new forward migration.
