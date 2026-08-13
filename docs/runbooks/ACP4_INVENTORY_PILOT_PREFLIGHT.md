# ACP-4 Inventory Pilot Preflight

**Status:** READY TO RUN — SELECT-ONLY  
**Runtime impact:** none; all permission keys remain `SHADOW`.

## Purpose

This gate proves whether the nine Inventory permission keys can be cut over as
one safe batch. It does not enable custom permission, modify an override, or
change existing role behavior.

Run:

`supabase/diagnostics/acp_phase4_inventory_pilot_preflight.sql`

## Interpretation

- `BLOCKER`: stop. Do not change any Inventory key to `ENFORCED`.
- `REVIEW`: inspect partial/unknown runtime hook state before implementation.
- `SETUP`: expected before ACP-4 implementation; permission hooks are not yet
  wired into business routines.
- `PASS`: live invariant is ready.
- `INFO`: inventory only; no automatic decision.

Expected before implementation:

- ACP-2 dependency and nine-key catalog contract `PASS`;
- keys remain `SHADOW`;
- protected Stock/FIFO/Movement direct write boundary `PASS`;
- all canonical Inventory routines exist;
- runtime permission hook is `SETUP` because ACP-4 cutover is not built yet;
- simple-master direct-write may reveal a `BLOCKER`. If so, Category/UOM/
  Warehouse/Store/Terminal mutations must receive a guarded server boundary
  before `inventory.master_data` can be enforced.

## Required Output

Send the complete result table. Aggregate counts and relation names are safe;
do not send user IDs, emails, business names, tokens, or credentials.

## Cutover Boundary

Do not manually update `access_permission_catalog.enforcement_status`. After
preflight review, ACP-4 must use a forward migration/config version and enforce
the same effective capability at navigation, direct route, Route Handler,
business RPC, export/import, and final workflow boundaries.

No override must preserve exact role behavior. `LIHAT_SAJA`, `OPERASIONAL`,
and `TANPA_AKSES` may only reduce that baseline.
