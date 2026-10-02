# Sales Export Net Detail — Rollout

Status starts at `LOCAL READY`. Do not label the feature live from local lint or
SQL files alone.

## Production database order

Run each file in full, in this exact order:

1. `supabase/diagnostics/sales_export_net_sales_detail_preflight.sql`
2. `supabase/migrations/20261002100000_sales_export_net_sales_detail.sql`
3. `supabase/tests/sales_export_net_sales_detail_behavior.sql`
4. `supabase/diagnostics/sales_export_net_sales_detail_postflight.sql`

Stop when any required row is not `PASS`. `INFO` is inventory, not failure.
Do not edit an assertion merely to turn a Production failure green.

## Client rollout

Deploy the Backoffice only after all four database steps pass. The client calls
the expanded composite RPC, so deploying it before the migration would produce
an empty new sheet and would not satisfy the feature contract.

## Authenticated smoke

For KMS, SMS, and LSM separately:

1. export a range containing at least one active Invoice and one returned or
   canceled Invoice;
2. verify the existing `Daftar Invoice` and `Detail Produk` values are unchanged;
3. verify `Detail Penjualan Bersih` exists and uses base UOM;
4. verify `Qty Penjualan Bersih` follows Invoice minus cancel minus Return;
5. verify a `DESTROY` Return lowers net Sales but not net Stock out;
6. verify a `RESTOCK` Return lowers both;
7. verify the known corrected SMS Invoice `INV-20260827-0000000072` has zero net
   Sales and zero net Stock for T20B/T22B;
8. verify cross-Company data is absent.

## Status reporting

- `DATABASE LIVE`: migration plus behavior and postflight pass.
- `CLIENT DEPLOYED`: matching route build is deployed.
- `SMOKE PASS`: authenticated steps above pass.
- `UAT PASS`: user accepts the sheet for operational reconciliation.

## Rollback

No business-data rollback is needed because the feature is read-only. Before
client deployment, restore the previous composite wrapper, drop only the new
private core, and remove the exact ledger row. After deployment, ship a forward
fix instead of removing the payload member.
