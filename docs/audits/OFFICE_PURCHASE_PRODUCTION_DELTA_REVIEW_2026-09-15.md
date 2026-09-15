# Production delta review — 2026-09-15

Status: INVENTORY REVIEWED; TARGETED PRODUCTION GUARDS USER-CONFIRMED PASS;
MANUAL INSTALL PACKAGE READY, PRODUCTION MIGRATION NOT EXECUTED.
Input: user supplied three read-only Production outputs, catalog attachment
`b6084697-873e-41bd-a03a-2f89d38dc67a`; no agent Production connection/mutation.

## Findings

- Catalog complete: all 10 kind-array counts match declarations; 212 ledger rows,
  219 relations, 2338 constraints, 884 indexes, 207 policies, 728 routines,
  207 triggers, 14 enums, 5 extensions and one execution-contract entry.
- Local set: 89 candidate migrations + two verified dependencies/forward fixes.
  Production already has only candidate `20260910100000`; 90 files remain
  ledger-missing: 88 base delta + `20260825131000` and `20260915100000`.
  Missing-file lexical order is NOT rollout order: use the rehearsed manifest
  checkpoints and compatibility insertion boundaries. Do not replay installed hotfix.
- 702/728 Production routine definitions equal final-clone digest; 26 differ.
  24 names have explicit declarations in the rehearsed chain. The two scanner
  exceptions are dynamic rewrites: Retail Dispatch in `20260910153000`, user
  role assignment in `20260909130000`. Neither is unexplained merely because
  the scanner lacks a CREATE declaration. This accounts for writer locations,
  not a proof every migration input regex/data precondition will pass Production.
- After canonical JSON property-order comparison: 11 shared relation shapes
  differ, 8 shared constraints differ; shared trigger/index/policy definitions
  match. One enum differs (`stock_movement_type`); pg_cron absent in Production.
  Two old Product/UOM unique constraints/indexes exist only in Production;
  migration `20260913110000` explicitly replaces both, so this difference is expected.
  No Production-only table, trigger, policy, enum or extension was found.
- Production Finance/offline queues PASS at capture time. Open PO count51 and
  identity digest ba3cb82575f879bc9ff7de405f20f857 still equal clone.
- Existing posted journal lines/journals, Supplier Bill/Payment fingerprints
  equal retained clone. Sales278/693, Receipt48/lines307, Movement615, Event259,
  Session103 and Stock/FIFO/Purchase row fingerprints differ. These are current
  baselines, not proof of corruption or grounds for unconditional fresh clone.

## Targeted next check, not a new full rehearsal

Receipt count increased16 ->48 while open PO identities remain unchanged. Counts
cannot establish whether active BACKOFFICE Drafts are unique. Final migration
`20260914180000` creates a unique index per Company/PO/Warehouse. Check the exact
existing duplicate predicate, plus legacy negative-stock evidence predicates
from `20260910153000`, with
[sensitive-row SELECT](../../supabase/diagnostics/office_purchase_production_sensitive_rows.sql).
It also reports current Receipt/PO statuses and the missing Receipt dependency.

Clone test: sensitive-row query exit0; three guard rows PASS; status inventories
returned. Zero invalid rows here is data-precondition evidence, not behavior proof.
User supplied Production result: all three data guards PASS;39 BACKOFFICE Drafts,
4 BACKOFFICE Canceled,1 BACKOFFICE Posted and4 POS Posted; Receipt dependency absent
but its prerequisite installed. No deleting duplicate Drafts,
guard removal, schema/runtime patch or deployment was performed.

## Compatibility / next boundary

Added comparison helper normalizes object names and JSON property ordering;
first serializer comparison overreported format differences, corrected/retested.
This is diagnostics only; no Stock/FIFO/Finance/audit writers or business flow change.
On relevant Production guard failure, inspect rows/lineage and design an audited
targeted fix/test on existing clone. Fresh clone is conditional, not automatic.
Final exact backfill inventory is recaptured after prerequisites, not inferred
from today's preliminary zero candidates. Backup, final queue checks, authenticated
smoke/UAT and explicit manual migration/deploy approval remain separate gates.
