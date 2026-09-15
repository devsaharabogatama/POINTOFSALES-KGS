WITH checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909142000'
  UNION ALL
  SELECT 'required_revision_status_columns',CASE WHEN count(*)=5 THEN 'PASS' ELSE 'FAIL' END,
    abs(5-count(*))::bigint,jsonb_build_object('expected',5,'columnRows',count(*))
  FROM information_schema.columns WHERE table_schema='public'
    AND table_name='backoffice_sales_orders' AND column_name IN(
      'fulfillment_status','fulfillment_status_updated_at','revision_count',
      'last_revised_at','last_revised_by')
  UNION ALL
  SELECT 'revision_status_routine_contract',
    CASE WHEN to_regprocedure('public.get_backoffice_sales_orders_v2(text,text,text,date,date,text,integer)') IS NOT NULL
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN to_regprocedure('public.get_backoffice_sales_orders_v2(text,text,text,date,date,text,integer)') IS NOT NULL
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('readerExists',to_regprocedure('public.get_backoffice_sales_orders_v2(text,text,text,date,date,text,integer)') IS NOT NULL)
  UNION ALL
  SELECT 'confirmed_revision_definition_contract',
    CASE WHEN body LIKE '%BACKOFFICE_SALES_ORDER_REVISION_REASON_REQUIRED%'
      AND body LIKE '%BACKOFFICE_SALES_ORDER_REVISION_REQUIRES_RETURN_OR_FULFILLMENT_SYNC%'
      AND body LIKE '%THEN ''REVISE''%' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN body LIKE '%BACKOFFICE_SALES_ORDER_REVISION_REASON_REQUIRED%'
      AND body LIKE '%BACKOFFICE_SALES_ORDER_REVISION_REQUIRES_RETURN_OR_FULFILLMENT_SYNC%'
      AND body LIKE '%THEN ''REVISE''%' THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('routineRows',1)
  FROM (SELECT pg_get_functiondef(
    'public.save_backoffice_sales_order_draft_before_pricelist_header(uuid,bigint,uuid,jsonb)'::regprocedure) body) definition
  UNION ALL
  SELECT 'fulfillment_status_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_orders WHERE
    (status IN('DRAFT','SENT') AND fulfillment_status<>'QUOTATION')
    OR (status='CONFIRMED' AND fulfillment_status NOT IN('CONFIRMED','PREPARING',
      'PARTIALLY_SHIPPED','IN_TRANSIT','COMPLETED'))
    OR (status='CANCELED' AND fulfillment_status<>'CANCELED')
    OR revision_count<0
    OR ((last_revised_at IS NULL)<>(last_revised_by IS NULL))
  UNION ALL
  SELECT 'browser_revision_runtime_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('directPrivilegeRows',count(*))
  FROM information_schema.table_privileges WHERE table_schema='public'
    AND table_name IN('backoffice_sales_orders','backoffice_sales_order_audit',
      'backoffice_sales_order_operations') AND grantee IN('anon','authenticated')
    AND privilege_type IN('INSERT','UPDATE','DELETE')
  UNION ALL
  SELECT 'revision_status_runtime_inventory','INFO',0::bigint,jsonb_build_object(
    'quotations',count(*) FILTER(WHERE order_no IS NULL),
    'salesOrders',count(*) FILTER(WHERE order_no IS NOT NULL),
    'confirmed',count(*) FILTER(WHERE fulfillment_status='CONFIRMED'),
    'inTransit',count(*) FILTER(WHERE fulfillment_status='IN_TRANSIT'),
    'completed',count(*) FILTER(WHERE fulfillment_status='COMPLETED'),
    'revisions',COALESCE(sum(revision_count),0))
  FROM public.backoffice_sales_orders
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
