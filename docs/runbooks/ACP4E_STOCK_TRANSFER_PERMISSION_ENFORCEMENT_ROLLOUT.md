# ACP-4E Stock Transfer Permission Enforcement

Status: LOCAL READY; manual Supabase rollout and authenticated smoke pending.

## Boundary

ACP-4E enforces exactly `inventory.stock_transfers`:

- `VIEW`: navigation, list/detail, Product/Gudang references, balances, and proof;
- `CREATE_DRAFT`: create only;
- `EDIT_DRAFT`: edit existing Draft only;
- `POST`: existing atomic FIFO relocation and paired Movement core;
- `CANCEL_FINAL`: cancellation of Draft under the existing role baseline.

The browser no longer reads the four Transfer tables directly. One guarded
composed RPC supplies Transfer data and narrow Product/Gudang references, so a
Finance/Accounting viewer does not need `inventory.master_data`. UUIDs remain
backend identities. No Stock, FIFO, Movement, document lifecycle, role baseline,
or idempotency behavior is changed.

## Manual SQL order

Run each file in full and stop on any error or `FAIL` row:

1. `supabase/migrations/20260812170000_acp_phase4e_stock_transfer_permission_enforcement.sql`
2. `supabase/diagnostics/acp_phase4e_stock_transfer_permission_postflight.sql`
3. `supabase/tests/acp_phase4e_stock_transfer_permission_tests.sql`
4. repeat step 2
5. `supabase/diagnostics/acp_phase4_inventory_pilot_preflight.sql`

Expected behavioral notice:

`TEST PASSED: Stock Transfer permission is capability-separated, tenant-safe, and direct browser reads are closed.`

## Authenticated smoke

1. `IKUTI_ROLE`: Warehouse Admin can View/Create/Edit/Post/Cancel; Finance and
   Accounting remain View-only.
2. `LIHAT_SAJA`: page/detail work, all mutation actions disappear and direct API
   calls are rejected.
3. `OPERASIONAL`: Create/Edit work, Post/Cancel stay hidden and rejected.
4. `TANPA_AKSES`: Home/Fast Link omit Transfer and direct route/API/RPC reject.
5. Switch Company A/B and verify override, documents, Gudang, Product, balances,
   FIFO proof, and Movement proof never cross tenant.
6. Post one disposable Draft and verify the same two Movement rows and FIFO
   relocation behavior as before ACP-4E.

## Compatibility and recovery

Public mutation signatures remain unchanged; their proven implementations were
moved behind guarded wrappers. `service_role` retains table and private-core
access. If authenticated smoke fails, restore the user override to `IKUTI_ROLE`
and issue a forward fix. Do not edit an applied migration, restore browser table
SELECT, or add a client-side purpose bypass.
