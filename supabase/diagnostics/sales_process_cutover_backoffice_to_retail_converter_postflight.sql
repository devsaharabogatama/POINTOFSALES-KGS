-- SELECT-only verification for 20260911110000. Run the entire file.
WITH checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260911110000'
  UNION ALL
  SELECT 'step_4c_required_routines',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    (3-count(*))::bigint,jsonb_build_object('expected',3,'routineRows',count(*))
  FROM (VALUES
    (to_regprocedure('private.get_sales_process_cutover_preview_before_step_4c(uuid,text)')),
    (to_regprocedure('private.get_sales_process_cutover_preview_core(uuid,text)')),
    (to_regprocedure('private.convert_backoffice_order_to_retail_sale(uuid,uuid,uuid,uuid)'))
  ) routine(oid) WHERE oid IS NOT NULL
  UNION ALL
  SELECT 'step_4c_converter_security_contract',
    CASE WHEN count(*)=1 AND bool_and(pro.prosecdef) AND bool_and(pro.provolatile='v')
      AND bool_and(array_to_string(pro.proconfig,',') LIKE '%statement_timeout=15s%')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(pro.prosecdef) AND bool_and(pro.provolatile='v')
      AND bool_and(array_to_string(pro.proconfig,',') LIKE '%statement_timeout=15s%')
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('routineRows',count(*),'securityDefiner',COALESCE(bool_and(pro.prosecdef),false),
      'volatility',min(pro.provolatile),'config',min(pro.proconfig::text))
  FROM pg_proc pro WHERE pro.oid=
    to_regprocedure('private.convert_backoffice_order_to_retail_sale(uuid,uuid,uuid,uuid)')
  UNION ALL
  SELECT 'step_4c_private_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='private' AND privilege.grantee IN('anon','authenticated')
    AND privilege.routine_name IN('convert_backoffice_order_to_retail_sale',
      'get_sales_process_cutover_preview_before_step_4c')
  UNION ALL
  SELECT 'step_4c_public_apply_boundary',
    CASE WHEN to_regprocedure('public.apply_sales_process_cutover_plan(uuid,bigint,uuid)')
      IS NULL THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN to_regprocedure('public.apply_sales_process_cutover_plan(uuid,bigint,uuid)')
      IS NULL THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('publicApplyAbsent',
      to_regprocedure('public.apply_sales_process_cutover_plan(uuid,bigint,uuid)') IS NULL)
  UNION ALL
  SELECT 'step_4c_preview_version_contract',
    CASE WHEN pg_get_functiondef(
      'private.get_sales_process_cutover_preview_core(uuid,text)'::regprocedure)
      ~ 'previewVersion''[[:space:]]*,[[:space:]]*3' AND pg_get_functiondef(
      'private.get_sales_process_cutover_preview_core(uuid,text)'::regprocedure)
      LIKE '%FUTURE_NON_TEMPO_MUST_FINISH_IN_BACKOFFICE%' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN pg_get_functiondef(
      'private.get_sales_process_cutover_preview_core(uuid,text)'::regprocedure)
      ~ 'previewVersion''[[:space:]]*,[[:space:]]*3' AND pg_get_functiondef(
      'private.get_sales_process_cutover_preview_core(uuid,text)'::regprocedure)
      LIKE '%FUTURE_NON_TEMPO_MUST_FINISH_IN_BACKOFFICE%' THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('required','Preview v3 with future non-TEMPO blocker')
  UNION ALL
  SELECT 'step_4c_target_draft_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.sales_headers sale
  WHERE sale.sales_origin='BACKOFFICE_CUTOVER' AND (
    sale.sales_process_mode<>'RETAIL_CONFIRM_INVOICE' OR sale.document_status<>'DRAFT'
    OR sale.order_runtime_status<>'DRAFT_INPUT' OR sale.session_id IS NOT NULL
    OR sale.pos_id IS NOT NULL OR sale.created_session_id IS NOT NULL
    OR EXISTS(SELECT 1 FROM public.sales_stock_reservations reservation
      WHERE reservation.company_id=sale.company_id AND reservation.sales_id=sale.id)
    OR EXISTS(SELECT 1 FROM public.sales_invoice_snapshots invoice
      WHERE invoice.company_id=sale.company_id AND invoice.sales_id=sale.id))
  UNION ALL
  SELECT 'step_4c_source_target_lineage_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.sales_headers target
  LEFT JOIN public.backoffice_sales_orders source
    ON source.company_id=target.company_id
   AND source.id::text=target.payload_snapshot->>'cutoverSourceDocumentId'
  WHERE target.sales_origin='BACKOFFICE_CUTOVER'
    AND (source.id IS NULL OR source.status<>'CANCELED')
  UNION ALL
  SELECT 'step_4c_runtime_inventory','INFO',0::bigint,
    jsonb_build_object('targets',count(*),'scheduledTargets',count(*) FILTER(
      WHERE order_timing_mode='SCHEDULED'))
  FROM public.sales_headers WHERE sales_origin='BACKOFFICE_CUTOVER'
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
