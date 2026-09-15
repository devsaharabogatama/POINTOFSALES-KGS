-- SELECT-only postflight for 20260912123000.
WITH checks AS (
 SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
 abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
 FROM private.kgs_schema_migrations WHERE version='20260912123000'
 UNION ALL SELECT 'accepted_overage_columns',CASE WHEN count(*)=8 THEN 'PASS' ELSE 'FAIL' END,
 abs(8-count(*)),jsonb_build_object('expected',8,'present',count(*))
 FROM information_schema.columns WHERE table_schema='public' AND (
  (table_name='backoffice_sales_delivery_discrepancy_lines' AND column_name IN('accepted_overage_base_qty','draft_overage_invoice_allocated_base_qty','invoiced_overage_base_qty','overage_to_invoice_base_qty'))
  OR (table_name IN('backoffice_sales_invoice_lines','backoffice_sales_invoice_quantity_allocations') AND column_name IN('source_kind','discrepancy_line_id')))
 UNION ALL SELECT 'accepted_overage_trigger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
 abs(1-count(*)),jsonb_build_object('triggerRows',count(*)) FROM pg_trigger
 WHERE tgrelid='public.backoffice_sales_invoice_quantity_allocations'::regclass
   AND tgname='backoffice_sales_invoice_overage_source_validate' AND NOT tgisinternal
 UNION ALL SELECT 'legacy_invoice_source_backfill',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
 count(*),jsonb_build_object('invalidRows',count(*)) FROM (
  SELECT id FROM public.backoffice_sales_invoice_lines WHERE source_kind<>'SALES_ORDER' OR discrepancy_line_id IS NOT NULL
  UNION ALL SELECT id FROM public.backoffice_sales_invoice_quantity_allocations WHERE source_kind<>'SALES_ORDER' OR discrepancy_line_id IS NOT NULL) invalid
 UNION ALL SELECT 'accepted_overage_invoice_runtime_inventory','INFO',0,jsonb_build_object(
  'invoiceableOverage',(SELECT count(*) FROM public.backoffice_sales_delivery_discrepancy_lines WHERE overage_to_invoice_base_qty>0),
  'overageInvoiceLines',(SELECT count(*) FROM public.backoffice_sales_invoice_lines WHERE source_kind='ACCEPTED_OVERAGE'))
)
SELECT * FROM checks ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
