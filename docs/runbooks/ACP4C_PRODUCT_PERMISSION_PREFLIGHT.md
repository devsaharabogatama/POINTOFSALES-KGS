# ACP-4C Product Permission Preflight

Status: SELECT-only diagnostic local-ready. No Product permission enforcement
is authorized by this file.

## Why this is a separate slice

`inventory.products` owns Product + Product-UOM atomic management. Product
reference reads are also consumed by Stock, Pricelist, Bundle, Supplier,
Opening Stock, and other workflows. Therefore the existing shared Product GET
route cannot simply be denied when `inventory.products` is hidden. The cutover
must introduce a guarded Product-management read while preserving separately
authorized reference reads; a client-supplied `purpose` flag is not an
authorization boundary.

The same slice must cover:

- Product + Product-UOM create/update and tax assignment;
- navigation, Product-management list, and direct page/API access;
- Product export/import visibility and guarded import job creation/commit;
- history immutability and conversion locks;
- absent-override role parity, all presets, and two-Company isolation;
- explicit non-ownership of Bundle and Product-Supplier workflows.

## Run

Execute
`supabase/diagnostics/acp_phase4c_product_permission_preflight.sql` in the
Supabase SQL Editor and return every row. This is one SELECT statement and does
not mutate schema, grants, catalog, or business data.

Stop before implementation if any `BLOCKER` appears. `SETUP` is expected for
permission hooks before ACP-4C implementation. `REVIEW` must be resolved by
design, not ignored. Do not manually change `inventory.products` from SHADOW.
