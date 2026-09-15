-- SELECT-only postflight for Step 4/6.5C2B. Run the entire file.
WITH definitions AS (
  SELECT
    pg_get_functiondef('private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(uuid,bigint,uuid,uuid,jsonb)'::regprocedure) base_def,
    pg_get_functiondef('private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)'::regprocedure) wrapper_def,
    pg_get_functiondef('public.cancel_backoffice_sales_invoice_draft(uuid,bigint,uuid,text)'::regprocedure) cancel_def,
    pg_get_functiondef('public.post_backoffice_sales_invoice(uuid,bigint,uuid)'::regprocedure) post_def,
    pg_get_functiondef('private.trg_backoffice_sales_invoice_accepted_overage_lines()'::regprocedure) overage_def
), checks AS (
  SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260912124000'
  UNION ALL
  SELECT 'c2b_required_routines',CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
    abs(4-count(*))::bigint,jsonb_build_object('expected',4,'present',count(*))
  FROM (VALUES
    (to_regprocedure('private.validate_backoffice_sales_invoice_overage_source()')),
    (to_regprocedure('private.trg_backoffice_sales_invoice_overage_counter()')),
    (to_regprocedure('private.trg_backoffice_sales_invoice_accepted_overage_lines()')),
    (to_regprocedure('private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)'))
  ) required(oid) WHERE oid IS NOT NULL
  UNION ALL
  SELECT 'c2b_trigger_contract',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(2-count(*))::bigint,jsonb_build_object('expected',2,'present',count(*))
  FROM pg_trigger WHERE NOT tgisinternal AND tgname IN(
    'backoffice_sales_invoice_overage_counter','backoffice_sales_invoice_accepted_overage_lines')
  UNION ALL
  SELECT 'c2b_call_chain_contract',CASE WHEN position('acceptedOverageLines' in base_def)>0
      AND position($needle$allocation.source_kind='SALES_ORDER'$needle$ in base_def)>0
      AND position('backoffice_invoice_accepted_overage_lines' in wrapper_def)>0
      AND position($needle$allocation.source_kind='SALES_ORDER'$needle$ in cancel_def)>0
      AND position($needle$allocation.source_kind='SALES_ORDER'$needle$ in post_def)>0
      AND position('PROPORTIONAL_LAST_REMAINDER' in overage_def)>0
      AND position('PER_INVOICE_LAST_REMAINDER' in overage_def)>0
    THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('acceptedOverageLines' in base_def)>0
      AND position($needle$allocation.source_kind='SALES_ORDER'$needle$ in base_def)>0
      AND position('backoffice_invoice_accepted_overage_lines' in wrapper_def)>0
      AND position($needle$allocation.source_kind='SALES_ORDER'$needle$ in cancel_def)>0
      AND position($needle$allocation.source_kind='SALES_ORDER'$needle$ in post_def)>0
      AND position('PROPORTIONAL_LAST_REMAINDER' in overage_def)>0
      AND position('PER_INVOICE_LAST_REMAINDER' in overage_def)>0 THEN 0 ELSE 1 END,
    jsonb_build_object('baseAcceptsOverage',position('acceptedOverageLines' in base_def)>0,
      'baseSeparatesCounters',position($needle$allocation.source_kind='SALES_ORDER'$needle$ in base_def)>0,
      'wrapperSuppliesOverage',position('backoffice_invoice_accepted_overage_lines' in wrapper_def)>0,
      'cancelSeparatesCounters',position($needle$allocation.source_kind='SALES_ORDER'$needle$ in cancel_def)>0,
      'postSeparatesCounters',position($needle$allocation.source_kind='SALES_ORDER'$needle$ in post_def)>0,
      'proportionalDiscount',position('PROPORTIONAL_LAST_REMAINDER' in overage_def)>0,
      'invoiceTaxRemainder',position('PER_INVOICE_LAST_REMAINDER' in overage_def)>0)
  FROM definitions
  UNION ALL
  SELECT 'c2b_counter_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_delivery_discrepancy_lines line
  WHERE line.draft_overage_invoice_allocated_base_qty<>COALESCE((SELECT sum(a.allocated_base_qty)
      FROM public.backoffice_sales_invoice_quantity_allocations a
      WHERE a.company_id=line.company_id AND a.discrepancy_line_id=line.id
        AND a.source_kind='ACCEPTED_OVERAGE' AND a.status='HELD'),0)
    OR line.invoiced_overage_base_qty<>COALESCE((SELECT sum(a.allocated_base_qty)
      FROM public.backoffice_sales_invoice_quantity_allocations a
      WHERE a.company_id=line.company_id AND a.discrepancy_line_id=line.id
        AND a.source_kind='ACCEPTED_OVERAGE' AND a.status='POSTED'),0)
  UNION ALL
  SELECT 'c2b_private_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges
  WHERE routine_schema='private' AND grantee='authenticated'
    AND routine_name IN('validate_backoffice_sales_invoice_overage_source',
      'trg_backoffice_sales_invoice_overage_counter',
      'trg_backoffice_sales_invoice_accepted_overage_lines')
  UNION ALL
  SELECT 'c2b_runtime_inventory','INFO',0,jsonb_build_object(
    'heldOverageAllocations',count(*) FILTER(WHERE status='HELD'),
    'postedOverageAllocations',count(*) FILTER(WHERE status='POSTED'),
    'releasedOverageAllocations',count(*) FILTER(WHERE status='RELEASED'))
  FROM public.backoffice_sales_invoice_quantity_allocations WHERE source_kind='ACCEPTED_OVERAGE'
)
SELECT * FROM checks ORDER BY
  CASE status WHEN 'FAIL' THEN 0 WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
