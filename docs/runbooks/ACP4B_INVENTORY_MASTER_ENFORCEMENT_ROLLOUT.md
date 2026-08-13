# ACP-4B Inventory Master Enforcement Rollout

Status: LOCAL READY; manual Supabase rollout and authenticated smoke pending.

## Scope

This slice enforces exactly one permission key: `inventory.master_data`.
Product Category, UOM, Warehouse, and Product Category Tax assignment writes
remain available through their existing Backoffice flows, but every mutation
now requires the effective `MANAGE` capability server-side. Store and POS
Terminal remain read-only in this slice. All other permission keys remain
`SHADOW`.

Preset behavior for this key:

- `IKUTI_ROLE`: preserves the approved role baseline;
- `LIHAT_SAJA`: page remains visible, mutation is denied;
- `OPERASIONAL`: intentionally read-only because this master key exposes
  `VIEW/MANAGE`, not Draft operations;
- `TANPA_AKSES`: removes navigation visibility and rejects the page API and
  mutation RPCs.

## Manual rollout order

Run each file completely in Supabase SQL Editor. Stop on any error or any
postflight `FAIL`.

1. `supabase/migrations/20260812140000_acp_phase4b_inventory_master_enforcement.sql`
2. `supabase/diagnostics/acp_phase4b_inventory_master_enforcement_postflight.sql`
3. `supabase/tests/acp_phase4b_inventory_master_enforcement_tests.sql`
4. rerun step 2
5. rerun `supabase/diagnostics/acp_phase4_inventory_pilot_preflight.sql`

Expected behavior test notice:

`TEST PASSED: Master Inventory enforcement is tenant-safe, role-compatible, restriction-only, guarded, and audited.`

## Authenticated Backoffice smoke

Restart Backoffice after the migration, then use Company Owner/Admin to open
`Tim & Akses`, select a non-owner Inventory user, expand Inventory, and change
Master Inventory through this matrix:

1. `LIHAT_SAJA`: menu visible; add/edit buttons unavailable; direct mutation
   returns `CUSTOM_PERMISSION_DENIED`.
2. `OPERASIONAL`: same read-only result; it must not grant `MANAGE`.
3. `TANPA_AKSES`: Master Inventory absent from Home and Fast Link; direct page
   API returns 403.
4. `IKUTI_ROLE`: approved Warehouse/Admin role regains its original access.
5. switch to the other Company: the override must not follow the user across
   Company boundaries.

Also create and edit one Category, UOM, and Warehouse as an allowed role, and
save Category Tax assignment if Tax is enabled. Names—not internal UUIDs or
codes—remain the user-facing identity.

## Compatibility and recovery

Public UOM, Warehouse, and Category Tax RPC signatures are unchanged; their
proven implementations are retained as private cores. Existing Product and
reference-list reads remain compatible. No business rows or existing
overrides are backfilled.

This migration is forward-only. If smoke exposes a defect, do not revert the
catalog to `SHADOW` or restore direct table grants manually. Stop ACP rollout
and issue a new forward-fix migration. Existing role behavior is recovered per
user by selecting `IKUTI_ROLE` through the guarded editor.
