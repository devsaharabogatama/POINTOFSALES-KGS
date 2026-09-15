# Office historical visibility repair

User instruction: switching process must not hide existing inputs/history. This
repairs the existing Quotation/Sales Order list, not conversion eligibility.
Gate: closing compatibility / authenticated smoke; TEN-001, TEN-005, SLD history.

Observed chain: BackofficeSalesOrderView -> backoffice-orders GET ->
get_backoffice_sales_orders_v3 -> backoffice_sales_orders only. Existing
get_sales_documents reads invoice snapshots only, limited to500; it cannot
cover unconfirmed inputs. Actual clone schema audited before implementation.

Direct impact: additive read-only RPC get_office_retail_history(uuid default
null), authenticated Company-scoped API, existing list and read-only detail.
Draft input/scheduled sources appear with Quotations; other source statuses
with Sales Orders. Source status and number remain original, marked Retail.
Successfully converted sources are represented by their Office target in the
list; the original remains accessible by ID and through document lineage.

Downstream: existing Retail Invoice viewer/print/template remains canonical;
no Invoice/SO recreation, stock/reservation/FIFO/payment/session/Finance/audit
mutation, source status rewrite or transaction backfill. Additive RPC requires
the existing backoffice-orders VIEW capability, enforced server-side. No
service-role client or generic source-table exposure.

Regression risks: wrong status/date mapping, source/target duplicates, missing
unsnapshotted Drafts, stale Company response. Use explicit types, Company checks,
request cleanup and source IDs; missing RPC is an error, not empty history.
Read retry is stable, no mutation/idempotency changes. Rollback: revert UI/API
patch; leave additive reader installed, or drop only the new reader after client
rollback. No existing routines changed; no stock reset or history deletion.

Verification: schema/capability/lineage preflight; guarded migration; postflight
ACL/security checks; nonzero rollback read behavior with source coverage, detail,
retry/anonymous rejection and protected transaction fingerprints. Authenticated
Production UI smoke and user UAT remain manual gates, never inferred from build.
