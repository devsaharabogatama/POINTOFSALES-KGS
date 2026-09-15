# Backoffice SO Invoice Status Rollout

Target: isolated Development project `fkywtxucmyjvpwdiqpix` only. Do not run on Production or existing Staging.

Run the complete files in this order:

1. `supabase/diagnostics/backoffice_sales_order_invoice_status_preflight.sql`
2. `supabase/migrations/20260912140000_backoffice_sales_order_invoice_status.sql`
3. `supabase/tests/backoffice_sales_order_invoice_status_behavior.sql`
4. `supabase/diagnostics/backoffice_sales_order_invoice_status_postflight.sql`
5. Start Backoffice with `backoffice/scripts/start-backoffice-sales-development.ps1 -Action dev`, then smoke the Sales Order list.

Expected UI smoke:

- Sales Order exposes separate Delivery and Invoice status columns.
- Invoice filter returns only the selected status.
- `Siap dibuat` opens the existing Invoice editor.
- `Draft` opens that Draft directly.
- `Ditagih sebagian` and `Sudah ditagih` open the existing Invoice list scoped to the SO.
- Quotation, Stock, Dispatch, Payment, Finance and existing Invoice templates are unchanged.

Rollback policy: forward-fix only after manual database execution. Before rollout, local files may be reverted. The migration adds read-only routines and does not backfill or mutate operational rows.
