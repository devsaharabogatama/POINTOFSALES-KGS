# ACP-6E Supplier Invoice Permission Preflight

**Gate:** ACP-6E Finance cutover  
**Permission key:** `finance.supplier_invoices`  
**Runtime action:** none; diagnostic is SELECT-only

## Purpose

Audit the complete Supplier Invoice boundary before enforcement:

- Invoice, lines, Receipt/AP provisional allocations, tolerance and audit;
- Draft/Edit, validation final, cancellation, and tolerance-policy authority;
- Finance/Accounting read versus Owner/Admin/Finance operation baseline;
- Supplier Payment and Purchase Return as independent consumers;
- immutable validated snapshots and Financial Event HOLD boundary;
- tenant isolation, direct browser grants, override integrity, and totals.

## Run

Run the complete file:

`supabase/diagnostics/acp_phase6e_supplier_invoice_permission_preflight.sql`

Return every `check_name,status,details` row. Do not run only selected queries.

## Interpretation

- `BLOCKER`: stop; data, dependency, grants, or canonical runtime is unsafe.
- `REVIEW`: design boundary that enforcement must implement; it is not an
  automatic failure.
- `SETUP`: expected missing ACP read/hook runtime before implementation.
- `PASS`/`INFO`: safe baseline or inventory evidence.

The tolerance capability decision must be closed before migration. Existing
optional tolerance remains valid: NULL absolute thresholds do not block Invoice
matching. ACP must not make tolerance mandatory or process Finance HOLD events.

## Next Safe Step

Only after all output is reviewed with no unexplained `BLOCKER`, build one
complete ACP-6E enforcement slice with migration, composed read, guarded
capabilities, Backoffice cutover, postflight, rollback-safe behavior, G5 Invoice
regression, Supplier Payment regression, and closing smoke. Do not enforce
`finance.supplier_payments` in the same migration.
