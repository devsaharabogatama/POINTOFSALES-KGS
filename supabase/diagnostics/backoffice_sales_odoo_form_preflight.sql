-- Read-only preflight for Odoo-style Backoffice Sales form and default Warehouse.
WITH checks AS (
  SELECT 'runtime_dependency'::text check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',2,'ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260908120000','20260908121000')
  UNION ALL
  SELECT 'active_finance_posting_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'existing_order_warehouse_scope',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_orders document
  LEFT JOIN public.warehouses warehouse ON warehouse.company_id=document.company_id
    AND warehouse.id=document.warehouse_id AND warehouse.is_active
    AND warehouse.is_sale_source
    AND (warehouse.store_id IS NULL OR warehouse.store_id=document.store_id)
  WHERE warehouse.id IS NULL
  UNION ALL
  SELECT 'default_warehouse_candidate_inventory','INFO',jsonb_build_object(
    'activeCompanies',(SELECT count(*) FROM public.companies WHERE status='ACTIVE'),
    'saleSourceWarehouses',(SELECT count(*) FROM public.warehouses WHERE is_active AND is_sale_source),
    'configuredDefaults',(SELECT count(*) FROM public.company_features
      WHERE feature_code='backoffice_delivered_qty_sales_enabled'
        AND config ? 'defaultWarehouseId'))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
