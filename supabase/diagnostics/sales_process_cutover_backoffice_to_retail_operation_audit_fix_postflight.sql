-- SELECT-only postflight for 20260911111000.
WITH definition AS (
  SELECT pg_get_functiondef(
    'private.convert_backoffice_order_to_retail_sale(uuid,uuid,uuid,uuid)'::regprocedure
  ) body
), checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260911111000'
  UNION ALL
  SELECT 'step_4c_cancel_operation_before_audit_contract',
    CASE WHEN body LIKE '%INSERT INTO public.backoffice_sales_order_operations(company_id,operation_id,%'
      AND body LIKE '%VALUES(p_company_id,p_operation_id,''CANCEL'',v_source.id,%'
      AND body LIKE '%VALUES(p_company_id,v_source.id,p_operation_id,''CANCEL'',p_actor_id,%'
      AND body NOT LIKE '%VALUES(p_company_id,v_source.id,gen_random_uuid(),''CANCEL'',p_actor_id,%'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN body LIKE '%INSERT INTO public.backoffice_sales_order_operations(company_id,operation_id,%'
      AND body LIKE '%VALUES(p_company_id,p_operation_id,''CANCEL'',v_source.id,%'
      AND body LIKE '%VALUES(p_company_id,v_source.id,p_operation_id,''CANCEL'',p_actor_id,%'
      AND body NOT LIKE '%VALUES(p_company_id,v_source.id,gen_random_uuid(),''CANCEL'',p_actor_id,%'
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('required','Parent CANCEL operation precedes FK-bound order audit')
  FROM definition
  UNION ALL
  SELECT 'step_4c_converter_security_preserved',
    CASE WHEN count(*)=1 AND bool_and(pro.prosecdef) AND bool_and(pro.provolatile='v')
      AND bool_and(array_to_string(pro.proconfig,',') LIKE '%statement_timeout=15s%')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(pro.prosecdef) AND bool_and(pro.provolatile='v')
      AND bool_and(array_to_string(pro.proconfig,',') LIKE '%statement_timeout=15s%')
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('routineRows',count(*),'securityDefiner',COALESCE(bool_and(pro.prosecdef),false),
      'volatility',min(pro.provolatile),'config',min(pro.proconfig::text))
  FROM pg_proc pro WHERE pro.oid=to_regprocedure(
    'private.convert_backoffice_order_to_retail_sale(uuid,uuid,uuid,uuid)')
  UNION ALL
  SELECT 'step_4c_operation_audit_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_order_audit audit
  LEFT JOIN public.backoffice_sales_order_operations operation
    ON operation.company_id=audit.company_id AND operation.operation_id=audit.operation_id
  WHERE operation.id IS NULL
  UNION ALL
  SELECT 'step_4c_cutover_cancel_lineage_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.sales_headers target
  JOIN public.backoffice_sales_orders source
    ON source.company_id=target.company_id
   AND source.id::text=target.payload_snapshot->>'cutoverSourceDocumentId'
  LEFT JOIN public.backoffice_sales_order_operations operation
    ON operation.company_id=source.company_id AND operation.operation_id=target.client_transaction_id
      AND operation.sales_order_id=source.id AND operation.operation_type='CANCEL'
  LEFT JOIN public.backoffice_sales_order_audit audit
    ON audit.company_id=source.company_id AND audit.operation_id=target.client_transaction_id
      AND audit.sales_order_id=source.id AND audit.action='CANCEL'
  WHERE target.sales_origin='BACKOFFICE_CUTOVER'
    AND source.order_no IS NOT NULL AND (operation.id IS NULL OR audit.id IS NULL)
  UNION ALL
  SELECT 'step_4c_audit_fix_runtime_inventory','INFO',0::bigint,
    jsonb_build_object('cutoverTargets',count(*),'confirmedSourceTargets',count(*) FILTER(
      WHERE source.order_no IS NOT NULL))
  FROM public.sales_headers target
  LEFT JOIN public.backoffice_sales_orders source
    ON source.company_id=target.company_id
   AND source.id::text=target.payload_snapshot->>'cutoverSourceDocumentId'
  WHERE target.sales_origin='BACKOFFICE_CUTOVER'
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
