# ACP-2 Shadow Permission Foundation Rollout

**Status:** LOCAL READY — MANUAL DATABASE ROLLOUT REQUIRED  
**Runtime impact:** none; all permission keys remain `SHADOW`.

## Decision

Role existing remains the production authority. Migration adds a stable catalog,
versioned per-user/Company restriction, immutable audit, and guarded resolver/
save RPC. Navigation, Route Handler, business RPC, and RLS do not consume the
effective result until later cutover phases.

`IKUTI_ROLE` is represented by no override row. Supported stored presets are
`LIHAT_SAJA`, `OPERASIONAL`, and `TANPA_AKSES`. The resolver returns both
baseline and hypothetical effective capabilities plus `enforced=false`.

## Order

1. Confirm latest ACP-1 output has zero `BLOCKER`.
2. Run migration:
   `supabase/migrations/20260812120000_acp_phase2_shadow_permission_foundation.sql`
3. Run postflight:
   `supabase/diagnostics/acp_phase2_shadow_permission_postflight.sql`
4. All rows except `INFO` must be `PASS`.
5. Run rollback-only behavior:
   `supabase/tests/acp_phase2_shadow_permission_foundation_tests.sql`
6. Rerun the ACP-2 postflight and ACP-1 preflight.

## Expected

- catalog has 32 rows;
- all 32 remain `SHADOW`, zero `ENFORCED`;
- `platform.companies` is non-customizable;
- direct browser writes to catalog/override/audit are false;
- resolver/list/save RPC are authenticated but enforce target hierarchy;
- no override row is created by migration;
- no existing role, membership, navigation, feature, Stock, Sale, or Finance
  data changes.

## Compatibility and Forward Fix

- no override preserves exact role behavior;
- even a saved override has no production effect in ACP-2;
- do not manually change `enforcement_status`;
- do not update the catalog directly from browser or SQL Editor;
- any contract correction must be a new forward migration.

## Rollback

Operational rollback requires no mutation because runtime is not cut over.
Leave tables and audit intact. If resolver preview must be disabled, revoke its
authenticated EXECUTE in a reviewed forward fix; do not drop history.

## Next Gate

After database PASS, ACP-3 may build consolidated User detail and read-only
permission preview. It must clearly label keys as `Belum aktif / mengikuti
role`; Inventory enforcement remains ACP-4.
