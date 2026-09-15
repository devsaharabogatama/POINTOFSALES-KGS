# Production database installed — reconciliation and client release

Status: PRODUCTION DATABASE USER-CONFIRMED PASS through all90 files and final
postflight. CLIENT DEPLOYED / AUTHENTICATED SMOKE / UAT not yet proved.

## Impact map / boundary

This preparation adds read-only diagnostics and docs, not application changes.
Stock/reservation/FIFO/payment/session/Finance/audit writers untouched; existing
transactional/idempotent/concurrency protections preserved. No env/link update,
secret access, production query, migration, git stage/commit/push or deploy by agent.
Do not activate Office, AUTO_RO/AUTO_PO or cutover while preparing release.

## 1. Manual data reconciliation — Production SQL Editor

Run the full
[legacy-value reconciliation](../../supabase/diagnostics/office_purchase_production_legacy_value_reconciliation.sql)
and export all17 rows as CSV. It embeds the Production baseline you supplied
before rollout, using its actual catalog column list, not clone counts.

New columns are excluded; missing legacy columns are BLOCKER. PASS means old
column values and total row count match exactly. REVIEW means mismatch requiring
analysis; approved backfill/empty-Draft metadata sync and legitimate operations
can explain changes. REVIEW is not permission to ignore differences or delete data.
The baseline was collected while business could continue, not an atomic maintenance
snapshot. New transactions between captures cannot be called migration corruption
without tracing IDs/time/amounts. Keep any immediate pre-maintenance CSV too.

Also run [full current fingerprints](../../supabase/diagnostics/office_purchase_clone_closing_fingerprints.sql)
as an AFTER checkpoint for later monitoring. Whole-row hash change from additive
schema alone is not evidence of changed old financial/stock values.

Agent clone-only syntax test:17 rows returned, no missing legacy columns. Some
REVIEW is expected because clone has older transactions. Initial SQL array/subquery
operator error caught locally, changed to explicit NOT EXISTS and retested exit0.
This is query execution evidence, not Production preservation PASS.

## 2. Client configuration — keep existing Production project

Operational follow-up: user reported11 tables PASS and six REVIEW and confirms
business continued. Run the full
[operational delta trace](../../supabase/diagnostics/office_purchase_production_operational_delta_trace.sql)
and export its six rows. It compares a chronological candidate subset to the stored
baseline digest and lists additional document/source IDs. A mismatching candidate
is not proof of corruption: baseline IDs and individual Stock quantities were not
captured. Current Stock trace remains REVIEW until quantities/lineage are explained.
Do not treat this query's clone execution as Production reconciliation PASS.

Source audit:

| App | Source root | Build | Output / framework |
| --- | --- | --- | --- |
| Backoffice | backoffice | npm run build | Next.js (not a static dist upload) |
| POS | pwa | npm run build | Vite dist |

Backoffice reads NEXT_PUBLIC_SUPABASE_URL and prioritizes NEXT_PUBLIC_SUPABASE_ANON_KEY
over NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY. If both keys exist, they must refer to
the same Production project. Server-auth reads SUPABASE_SERVICE_ROLE_KEY only
server-side. Never expose it via NEXT_PUBLIC_ or VITE_ variables.

Production URL must be https://nbxjslqojexjfogamnjt.supabase.co. Use the current
Production public anon/publishable key in the deployment dashboard, not keys from
clone/Development. If existing deployment settings already match, retain them.
Do not paste keys here or copy local .env.local into the repository/release.

POS needs explicit VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY for Production.
Its vite.config.ts falls back to ../backoffice public env if these are absent;
the local Backoffice env is Development, so do not build/upload POS using that
implicit fallback. Runtime won't switch projects simply because database migrated;
the build-time public URL/key is embedded in the client.

Do not run build:backoffice-sales/start-backoffice-sales-development or clone-build
helpers for Production. Those deliberately target isolated development/clone.
Use standard builds in the approved Production deployment environment. MADS_*
flags are used by development helpers; no application source gate was found that
requires enabling them to run Office in Production.

Existing backoffice/vercel.json only specifies schema, not account/project/env or
deployment root. Confirm root directories and target deployment project in the
actual hosting dashboard; this file alone does not prove correct configuration.
Builds previously passed locally are not evidence a Production artifact has been
built/deployed. Regenerate there; never upload .next from clone or dev dist.

## 3. Versioning and release — do not stage everything blindly

The worktree contains many existing user changes. Review the intended Backoffice/
PWA source and required dependencies/lockfiles together. Preserve unrelated work.
Do not git add . or commit all folders merely because migrations passed. Do not
publish local envs/.next/dist/exports, credentials, fixture data or HR sandbox.
Development scripts/tests/docs can be versioned for reproducibility but must not
be executed as deployment hooks/seed/migration automation on Production.

Before commit/push, review staged diff and any tracked env/artifacts, build root
and hosting auto-deploy branch. Commit/push can deploy automatically; require the
approved release window and target, rather than treating push as harmless versioning.
No selected commit/package artifact is claimed ready until that diff is reviewed.

## 4. Release / smoke matrix

After reconciliation is explained and release target/build gates clear:

1. Deploy Backoffice/POS client from the approved revision with Production env.
2. Retail first on a Company that stays Retail: login/session, catalog/pricelist,
   save/resume Draft, scheduled/revision, confirmation/reservation, SJ dispatch,
   Invoice, partial/full payment, cancellation/Return and Stock/FIFO/Finance trace.
3. Office pilot only after explicit Company activation: Quotation/SO, minus policy
   from Warehouse, DO/transit/customer receipt, Create Invoice/edit Draft/Post,
   payment history/paid status and balanced journals, no double quantity allocation.
4. Purchase MANUAL: RO->PO, generated Receipt/Qty edit, partial/full Receive,
   Bill Draft/edit/validate/post, partial/full Supplier Payment, Return/cancel.
   Bulk Receive: successful documents post; failed remain correctable.
5. Verify two Companies/custom Sales/Finance/Warehouse role denial, stale version,
   retry/concurrency and document history links. Browser authenticated testing,
   not zero operational rows or read-only postflight, is evidence for these paths.
6. POS service worker/cache: ensure no queued offline writes are discarded; close
   and reopen/update clients only through the existing update flow. Do not clear
   IndexedDB/site data while pending submissions exist. Monitor browser/API errors.

AUTO_RO/AUTO_PO activation is separate after manual cycle PASS. Office cutover
preview must retain/convert documents under existing approved classifier, not
mass update stock/reservations. Do not replace production data to match clone.

## 5. Recovery and completion

On client/API error, preserve request/document IDs and stop the failing path;
do not rerun installed migrations or reset DB. Previous client redeploy only
after RPC compatibility review. Database recovery uses audited forward-fix or
explicit restore plan; never delete transaction/audit history to force PASS.

Next agent boundary: user supplies reconciliation CSV; classify precise mismatches
and review intended source diff/release target. No automatic clone replay required.
Keep DATABASE LIVE, CLIENT DEPLOYED, SMOKE PASS and UAT PASS separate in handoff.
