# G6 Corrective Phase 6C - Statements and Reconciliation Rollout

## Scope

- POSTED-only P&L and Balance Sheet;
- non-posted Financial Event analysis, explicitly labeled
  `BELUM MASUK LAPORAN KEUANGAN`;
- current-only FIFO/AP/Customer Balance versus GL summary;
- no automatic adjustment;
- six versioned report definitions for every active Company;
- immutable reconciliation document/allocation foundation, read-only browser;
- 25 existing HOLD events remain untouched.

Historical reconciliation is intentionally rejected because current operational
tables do not reconstruct past subledger state reliably. A fake historical
number is not substituted.

## Manual order

1. Run `supabase/migrations/20260810230000_g6_phase6c_statements_pending_reconciliation.sql`.
2. Run `supabase/diagnostics/g6_phase6c_statements_pending_reconciliation_postflight.sql`.
3. Run `supabase/tests/g6_phase6c_statements_pending_reconciliation_tests.sql`.
4. Rerun Phase 6C preflight, Phase 6A/6B closing postflight, Phase 5/4/2, and G1 security regression.

Expected: every non-INFO postflight row `PASS`; behavioral notice begins
`TEST PASSED`. Test data and journals rollback.

## Compatibility and boundary

- Existing Trial Balance/GL signatures are unchanged.
- Existing live journal/event/queue rows are not mutated by migration.
- Reconciliation tables have no browser mutation RPC yet and start empty.
- Pending analysis never contributes to financial statement totals.
- FIFO–GL difference remains visible until explicit event resolvers are built;
  do not post a balancing adjustment merely to make the report zero.

After an applied migration, corrections must use a forward-only migration.
