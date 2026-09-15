# Production delta audit — use the completed clone rehearsal

Status: SOURCE READY; all three SELECT files executed successfully on the existing
clone; Production execution manual and not performed by agent.

## Purpose and impact map

User decision 2026-09-15: keep the completed historical-clone rehearsal and inspect
Production read-only before deciding any additional test. A newer transaction
count/digest alone does not require another clone or replay of all 88 migrations.

Direct impact: SQL audit files and documentation only. No UI/API/RPC/schema changes.
Downstream Stock/reservation/FIFO/payment/session/Finance/audit writers untouched.
No application RPC is executed. No fixtures, locks FOR UPDATE, seeds, deployment,
DDL/DML or business-mode switch. Catalog reads and aggregate scans consume resources;
run sequentially in a quiet period. No data rollback is needed for these SELECTs.

## Manual execution — current Production project only

Verify the dashboard project is `nbxjslqojexjfogamnjt`, not Development or rehearsal.
The server IP in SQL output is not a reliable Supabase project-ref guard.

Run each complete file separately in SQL Editor, then export its entire result CSV:

1. [Discovery / ledger / queues / transaction inventory](../../supabase/diagnostics/office_purchase_production_discovery_preflight.sql)
2. [Schema / constraints / trigger / RPC digest and permissions](../../supabase/diagnostics/office_purchase_production_delta_catalog.sql)
3. [Exact fingerprints for 17 existing transaction tables](../../supabase/diagnostics/office_purchase_clone_closing_fingerprints.sql)

File 3 is shared deliberately: it uses existing transaction tables and SELECT only,
despite its historical clone filename. It returns counts/digests, not transaction
contents. If a relation is missing or a query errors/timeouts, retain the error and
do not replace it with a made-up table, skip a guard or run any migration.

Export all rows, not only the first SQL Editor page; send the three CSV files.
File 2 groups all objects into one JSON array per catalog kind, so the default
SQL Editor row limit does not silently drop individual routines/tables.
Do not send credentials, API keys, connection strings or tokens. The catalog can
be larger than the other outputs. Execute sequentially, not all files concurrently.

These are three separate point-in-time reads while business continues. Differences
between runs can be legitimate concurrent transactions; this is not an atomic
before/after rollout proof. A final maintenance-window snapshot is required later.

## Interpretation — no automatic go/no-go from INFO

- Discovery PASS for queues means no active rows at capture time, not behavior proof.
  Active queue/offline rows are a rollout-time gate, not a new business-flow rule.
- Discovery candidate ledger excludes `20260825131000` and `20260915100000` by
  historical date range. File 2 includes the complete application ledger, including
  those versions. Entry digests include environment-specific installation metadata;
  do not interpret an entry digest difference as migration source checksum drift.
- The catalog is inventory, not a claim that every object should match the FINAL
  clone. Rehearsed migrations deliberately changed routines/columns/triggers.
  Compare each Production migration input with the audited expected call chain,
  distinguish expected missing Office objects from unknown pre-existing collisions.
- Fingerprints need not equal the historical clone while Production is operating.
  They provide the current baseline. Identify actual migration-sensitive rows and
  validate constraint/backfill preconditions; do not delete transactions to match.
- Discovery Receipt candidates are a preliminary inventory, not the exact final
  backfill set. Recapture with the final Receipt preflight after its prerequisites
  are installed, immediately before `20260914180000`.
- Analyze differences against manifest, installed guards and retained clone evidence.
  If a relevant mismatch exists, document the precise consumer/data impact and test
  that affected path on the existing clone. A fresh clone is conditional only when
  relevant Production state cannot be represented/proved on the current clone.

## Next boundary

After all outputs: produce the actual missing migration/dependency list, classified
drift and any targeted read-only row validation needed. This inventory package is
not a universal executable migration-preflight and does not authorize deployment.
Authenticated Retail/Office/Purchase/Finance smoke, custom-role/concurrency/bulk UAT,
backup/restore point, maintenance-window checks and explicit rollout approval remain.

No build or runtime configuration changed. No Production query executed by agent.

Clone verification: discovery 3 checks PASS and inventories returned; catalog
query exit 0; fingerprints returned all 17 tables and equal retained closing
values. This verifies SQL execution on clone, not Production preconditions.
