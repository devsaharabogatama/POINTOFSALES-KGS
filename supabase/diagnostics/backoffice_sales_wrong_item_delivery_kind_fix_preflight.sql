-- SELECT-only preflight for C3 Delivery-kind forward-fix. Run the whole file.
WITH function_fact AS (
  SELECT pg_get_functiondef(to_regprocedure(
    'private.resolve_backoffice_sales_overage_wrong_item_core(uuid,bigint,uuid,date,text)')) definition
), constraint_fact AS (
  SELECT pg_get_constraintdef(oid) definition
  FROM pg_constraint
  WHERE conrelid='public.backoffice_sales_delivery_orders'::regclass
    AND conname='backoffice_sales_delivery_orders_kind_check'
), checks AS (
  SELECT 'c3f_dependency_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260912130000'
  UNION ALL
  SELECT 'c3f_migration_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('existingRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260912131000'
  UNION ALL
  SELECT 'c3f_canonical_delivery_kind_contract',
    CASE WHEN count(*)=1 AND bool_and(position('BACKORDER' in definition)>0
      AND position('CORRECTION' in definition)=0) THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)=1 AND bool_and(position('BACKORDER' in definition)>0
      AND position('CORRECTION' in definition)=0) THEN 0 ELSE 1 END,
    jsonb_build_object('constraintRows',count(*),'definitions',coalesce(jsonb_agg(definition),'[]'::jsonb))
  FROM constraint_fact
  UNION ALL
  SELECT 'c3f_resolver_anchor_contract',
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE definition IS NOT NULL)=1
      AND bool_and((length(definition)-length(replace(definition,
        '''CORRECTION'',v_delivery.id,''READY''','')))
        /length('''CORRECTION'',v_delivery.id,''READY''')=1)
      AND bool_and(position('''BACKORDER'',v_delivery.id,''READY''' in definition)=0)
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE definition IS NOT NULL)=1
      AND bool_and((length(definition)-length(replace(definition,
        '''CORRECTION'',v_delivery.id,''READY''','')))
        /length('''CORRECTION'',v_delivery.id,''READY''')=1)
      AND bool_and(position('''BACKORDER'',v_delivery.id,''READY''' in definition)=0)
      THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*),'oldAnchorRows',count(*) FILTER(
      WHERE position('''CORRECTION'',v_delivery.id,''READY''' in definition)>0),'newAnchorRows',count(*) FILTER(
      WHERE position('''BACKORDER'',v_delivery.id,''READY''' in definition)>0))
  FROM function_fact
  UNION ALL
  SELECT 'c3f_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'c3f_nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'c3f_runtime_inventory','INFO',0,jsonb_build_object(
    'wrongItemCorrectionHeaders',count(*),'linkedDeliveries',count(delivery.id),
    'noncanonicalDeliveryKinds',count(*) FILTER(WHERE delivery.id IS NOT NULL
      AND delivery.delivery_kind<>'BACKORDER'))
  FROM public.backoffice_sales_discrepancy_backorders header
  LEFT JOIN public.backoffice_sales_delivery_orders delivery
    ON delivery.company_id=header.company_id AND delivery.id=header.backorder_delivery_order_id
  WHERE header.resolution_kind='WRONG_ITEM_CORRECTION'
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
