# Existing history visibility — additive patch

No reset, clone replacement, repetition of90 migrations, stock reset, historic
transaction recreation or process-setting change. Existing Production recovery
release remains installed. This patch adds one read-only reader and integrates
original Retail inputs/history into existing Quotation/Sales Order list.

Production manual SQL, each entire file:

1. [Preflight](../../supabase/diagnostics/office_retail_history_preflight.sql).
2. [Migration](../../supabase/migrations/20260916110000_office_retail_history_reader.sql).
3. [Postflight](../../supabase/diagnostics/office_retail_history_postflight.sql).

Behavior test is clone-only: canonical actor/Company feature/context fixture
rolled back; reads all original sources, details/lines and verifies protected
source/detail/stock/movement/event/journal values unchanged. User Production
should run read-only pre/post checks, not create fixture transactions.

Deploy client after reader installed. Existing source Draft input / scheduled
is listed with Quotations; other original statuses with Sales Orders. Retail
badge makes source clear; status/search/date/Invoice filters apply. Converted
source is not duplicated in the active list; source link in SO log opens the
original read-only document. Existing Invoice viewer and Company print settings
are reused. No new invoice/template/module tab.

Smoke: active KMS and LSM, clear filters; find old delivered and Draft input;
open original details and original Invoice; compare an existing converted SO,
open source log link; test search/order/delivery/due date filters; check Company
switch and restricted role. New Office creation/edit/post/Receive/payment flows
remain existing writers. No claim of authenticated Production smoke until user
has executed these checks.

Rollback: revert this scoped UI/API patch first; leaving additive reader is
safe. Optionally drop only public.get_office_retail_history(uuid) afterwards;
retain migration ledger/audit and original transaction data. Forward fix must
preserve original source IDs and avoid writer/converter changes.

## Local evidence

Clone preflight3PASS, additive migration exit0, postflight3PASS; nonzero history
behavior116 sources/all details and lines PASS, retry/anonymous/tenant scope,
protected transaction values unchanged; fixtures rolled back. Canonical recovery
fixture tests nonzero recovered-source dedupe, source-target and cross-Company
history denial exit0. Final scoped ESLint/tsc/filter tests exit0. Build85 pages
exit0 before final source-link JSX, then final TypeScript/lint pass. Production
installation and authenticated visual smoke are not claimed.

## Scoped Git delivery

Run from repository root after Production reader postflight PASS. Do not use
git add . (unrelated HR/bootstrap/dummy files are present). Review the staged
file list before commit; commands do not change Supabase or transactions.

```powershell
git add -- README.md docs/README.md docs/ACTIVE_DEVELOPMENT_HANDOFF.md docs/SALES_ORDER_DUAL_INVOICE_PROCESS_NOTES.md docs/audits/OFFICE_HISTORY_VISIBILITY_IMPACT_2026-09-16.md docs/runbooks/OFFICE_HISTORY_VISIBILITY_RELEASE_2026-09-16.md backoffice/src/components/BackofficeSalesOrderView.tsx backoffice/src/components/SalesDocumentView.tsx backoffice/src/components/OfficeRetailHistoryDetail.tsx backoffice/src/lib/office-retail-history.ts backoffice/src/app/api/sales/backoffice-orders/history/route.ts backoffice/scripts/test-office-retail-history.mjs supabase/diagnostics/office_history_reader_schema_audit.sql supabase/diagnostics/office_retail_history_preflight.sql supabase/diagnostics/office_retail_history_postflight.sql supabase/migrations/20260916110000_office_retail_history_reader.sql supabase/tests/office_retail_history_behavior.sql supabase/tests/retained_order_recovery_behavior.sql
git diff --cached --name-only
git commit -m "fix: show retained Retail history in Office sales lists"
if ($LASTEXITCODE -eq 0) { git push origin main }
```
