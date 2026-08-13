# ACP-4C Product Permission Enforcement Rollout

Status: DATABASE/POSTFLIGHT/BEHAVIOR USER-PASS; authenticated preset and
two-Company smoke remains in ACP closure.

## Enforced boundary

This slice enforces exactly `inventory.products` without changing approved
Product, UOM, Tax, Bundle, Product-Supplier, Stock, or import business flows.

- Product-management list requires effective `VIEW`.
- Product + Product-UOM create/update and Product Tax mutation require `MANAGE`.
- Product CSV catalog/export/template/import requires the matching effective
  `VIEW`/`EXPORT`/`IMPORT` capability.
- Product import create, stage, validate, and commit are type-aware guarded
  server-side. Other import types retain their own authority.
- The legacy full Product endpoint now requires Product `VIEW`. Separately
  authorized Stock/Pricelist/Bundle/Supplier workflows use a dedicated Product
  reference endpoint that requires `VIEW` from at least one approved consumer
  module. No client `purpose` flag is trusted.
- Bundle remains `sales.bundles`; Product-Supplier remains outside this key.

`LIHAT_SAJA` and `OPERASIONAL` are read-only here. `TANPA_AKSES` removes
Product management and Product Data Exchange. `IKUTI_ROLE` preserves the
approved role baseline. Cross-module reference pickers remain governed by
their own module authority.

## Manual SQL order

Run each complete file in Supabase SQL Editor. Stop on an SQL error or any
postflight `FAIL`.

1. `supabase/migrations/20260812150000_acp_phase4c_product_permission_enforcement.sql`
2. `supabase/diagnostics/acp_phase4c_product_permission_postflight.sql`
3. `supabase/tests/acp_phase4c_product_permission_tests.sql`
4. rerun step 2
5. rerun `supabase/diagnostics/acp_phase4_inventory_pilot_preflight.sql`

Expected notice:

`TEST PASSED: Product permission guards management/import while preserving tenant-safe cross-module reference reads and role parity.`

## Authenticated smoke

Using Owner/Admin, edit a non-owner Inventory user:

1. `LIHAT_SAJA`: Product visible, no Add/Edit; Product export/import absent and denied.
2. `OPERASIONAL`: same read-only result.
3. `TANPA_AKSES`: Product absent from Home/Fast Link and Data Exchange.
4. While Product is hidden, an otherwise authorized Stock/Price/Purchase
   Product picker must still load.
5. `IKUTI_ROLE`: the role regains its original Product mutation/import access.
6. Switch Company and verify the override does not cross tenant scope.

As an allowed role, create/update one Product with two UOMs and confirm
historical conversion/stock protection remains unchanged.

## Compatibility and recovery

All public Product and generic import RPC signatures remain intact; proven
implementations are private cores. Existing Product/history/import rows are not
rewritten. No Stock, Sale, Purchase, Bundle, or Product-Supplier row is changed.

Do not restore direct grants, edit the applied migration, or manually set the
catalog back to SHADOW. Stop and issue a forward-fix on live failure.
`IKUTI_ROLE` is the guarded per-user recovery path.
