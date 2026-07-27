# G2 Phase 35 — Full Master Import/Export Preflight

## Status

`COMPLETE — LIVE RESULT PASS/INFO 2026-07-24`

This gate prepares fixed CSV import/export for every user-creatable canonical
master currently exposed by Backoffice. It does not mutate schema or business
data.

## Run

Execute the entire file in Supabase SQL Editor:

```text
supabase/diagnostics/g2_phase35_full_master_import_preflight.sql
```

Expected:

- no `BLOCKER`;
- `g2_phase33_dependency = PASS`;
- `canonical_guarded_rpc_state = PASS`;
- duplicate/reference/group checks are `PASS`;
- `nonterminal_import_job_inventory` is informational. If nonzero, finish or
  abandon those jobs before the expansion migration.

Live result received:

- 15 checks returned only `PASS`/`INFO`;
- all 22 expected tables and 12 guarded RPC names are present;
- duplicate, ambiguity, grouped-master, and cross-reference checks are clean;
- no nonterminal import job exists.

Before migration is written, the fixed contract must incorporate the approved
automatic-code UX without replacing UUID as the canonical system identity.

## Scope After PASS

The additive implementation may extend import types for:

- Product and Product-UOM as one group;
- Product-Supplier;
- Customer Category and Customer;
- Pricelist plus rules/Store scope;
- Payment Method plus Store scope;
- Chart of Account, Transaction Category, mapping rule, Company fallback;
- Tax Rule plus effective version.

Existing Category/UOM/Warehouse/Supplier remains compatible.

## Excluded

- Company and Staff/password provisioning;
- system-owned Walk-In and internal Payment Methods;
- entitlement toggles;
- Product Brand until its canonical master exists;
- Opening Stock and all stock/transaction/journal imports.

These exclusions prevent CSV from bypassing security or transactional
invariants; they are not forgotten items.

## Fixed Contract

See `docs/MASTER_IMPORT_FIXED_CSV_CONTRACTS.md`. That file is the template
source of truth; UI labels may improve, but header names and grouping semantics
cannot change silently.

## Next Safe Step

After a clean result, write an additive migration that version-enables the new
import types, validators, preview, and atomic-per-group partial commit. Then add
postflight/behavioral tests before exposing the new templates in Backoffice.
