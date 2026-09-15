# Backoffice Quotation/Sales Order Runtime Rollout

Status 2026-09-09: database runtime and client compile are verified only on
isolated Development `fkywtxucmyjvpwdiqpix`. Production and old staging are
untouched. Feature is ON only for the isolated Development Company after a
guarded official-RPC fixture operation; authenticated client smoke is pending.

## Impact boundary

- Direct writes: `backoffice_sales_orders`, lines, operations, and audit only.
- Read dependency: Company/Store/Warehouse/Customer/Product-UOM/Pricelist and
  canonical read-only server price resolver.
- Explicitly excluded: POS `sales_headers`, Reservation, Stock/FIFO, Delivery,
  Invoice, Payment, and Finance.
- Feature `backoffice_delivered_qty_sales_enabled` is ON only for the isolated
  Development fixture Company. Production and old staging remain untouched.

## Applied chain

1. Preflight: `backoffice_sales_order_runtime_preflight.sql`.
2. Runtime: `20260908120000_backoffice_sales_order_runtime.sql`.
3. Structural postflight: `backoffice_sales_order_runtime_postflight.sql`.
4. Digest forward-fix: `20260908121000_backoffice_sales_order_runtime_digest_fix.sql`.
5. Forward-fix postflight:
   `backoffice_sales_order_runtime_digest_fix_postflight.sql`.
6. Rollback behavior: `backoffice_sales_order_runtime_behavior.sql`.
7. Closing structural postflight and migration dry-run.
8. Odoo-style Company Warehouse preflight:
   `backoffice_sales_odoo_form_preflight.sql`.
9. Default Warehouse migration:
   `20260909100000_backoffice_sales_odoo_form_default_warehouse.sql`.
10. Rollback-only behavior and structural postflight:
    `backoffice_sales_odoo_form_behavior.sql` and
    `backoffice_sales_odoo_form_postflight.sql`.
11. Canonical Sales tax preflight, forward migration, rollback behavior, and
    postflight: `backoffice_sales_tax_preflight.sql`,
    `20260909110000_backoffice_sales_canonical_tax_runtime.sql`,
    `backoffice_sales_canonical_tax_behavior.sql`, and
    `backoffice_sales_tax_postflight.sql`.
12. Pricelist header preflight and migration:
    `backoffice_sales_pricelist_header_preflight.sql` and
    `20260909120000_backoffice_sales_pricelist_header.sql`.
13. Pricelist structural/behavior gates:
    `backoffice_sales_pricelist_header_postflight.sql` and
    `backoffice_sales_pricelist_header_behavior.sql`.

## Evidence

- Seven public RPCs exist, use SECURITY DEFINER with hardened search path, are
  executable by authenticated only, and require ENFORCED permission + feature.
- Three private helpers are not executable by authenticated.
- Behavior PASS covers server pricing, Draft, exact retry, conflict, stale
  version, Send, Confirm, Cancel, audit, and downstream row-count equality.
- Test fixtures and temporary feature enablement are transactionally rolled back.
- Closing inventory is zero and feature enabled Company count is zero.
- Client lint and guarded Next production build PASS. The build guard printed
  the isolated Development ref and denied both production and old staging.
- Unauthenticated local smoke returns 200 for the app shell and 401 for the
  list/workspace API, proving the new proxy does not open anonymous access.
- In-app browser automation failed at the tool-host sandbox metadata boundary;
  therefore visual/authenticated smoke is explicitly not claimed.
- Default Warehouse behavior PASS covers valid Company default, workspace
  exposure, exclusion/rejection of non-sales Warehouse, and zero downstream
  effects. Structural postflight PASS covers two routines and the tenant/store
  guard trigger.
- The Odoo-inspired client view and module setting pass scoped ESLint and the
  guarded Next production build.
- Canonical tax behavior proves an inclusive 11% Sales rule resolves from the
  Product, snapshots identity/rate/base/amount, reconciles DPP + tax to gross,
  and leaves all downstream fulfillment/Finance counts unchanged. The UI line
  grid exposes Product, Description, Qty, UOM, Unit Price, Taxes, and Amount.

## Client smoke gate

1. Login as `localadmin@local.com`; verify menu visibility, empty state, and
   Settings -> Sales shows the configured default Warehouse.
2. Open Quotation Baru and verify Warehouse is automatic; override it only with
   another compatible sales Warehouse, then create and edit Draft.
   Verify the commercial header shows Pricelist, AUTO follows Customer/Global,
   and an explicit eligible Pricelist is preserved after save/reload.
3. Verify full-page status bar and tabs, send Quotation, confirm SO, and cancel
   a second Draft.
4. Verify reload, exact retry, stale version, Company switch reset, read-only
   role, and direct unauthenticated API denial.
5. Confirm Reservation, Stock/FIFO, Delivery, Invoice, Payment, and Finance row
   counts remain unchanged, then run POS retail regression.

## Forward/rollback rule

Before real runtime rows, Development-only objects can be dropped in reverse
dependency order. Once transaction rows exist, use forward-fix migrations;
never edit applied migration files. Client rollout must remain Development-only
until authenticated browser smoke and POS regression pass.
