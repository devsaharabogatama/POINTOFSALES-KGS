-- Read-only preflight for retained Retail -> Backoffice Return commercial bridge.
-- Run the entire file. It performs no writes.
WITH checks AS (
  SELECT 'retained_return_commercial_dependencies' check_name,
    CASE WHEN count(*)=11 THEN 'PASS' ELSE 'BLOCKER' END status,
    (11-count(*))::bigint violation_rows,
    jsonb_build_object('present',count(*),'expected',11) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260916110000','20260917110000','20260917120000',
    '20260917121000','20260917122000','20260917130000','20260917131000',
    '20260917150000','20260917151000','20260918100000','20260918110000')
  UNION ALL
  SELECT 'retained_return_commercial_column_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('existing',COALESCE(jsonb_agg(column_name),'[]'::jsonb))
  FROM information_schema.columns WHERE table_schema='public' AND (
    (table_name='backoffice_sales_returns' AND column_name IN(
      'source_kind','retail_sales_id','source_document_snapshot')) OR
    (table_name='backoffice_sales_return_lines' AND column_name IN(
      'source_kind','retail_sales_detail_id')))
  UNION ALL
  SELECT 'retained_return_commercial_routine_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('existing',COALESCE(jsonb_agg(routine),'[]'::jsonb))
  FROM (SELECT routine FROM unnest(ARRAY[
    'public.get_retained_retail_backoffice_return_source(uuid)',
    'public.save_retained_retail_backoffice_return_draft(uuid,bigint,uuid,uuid,jsonb)'
  ]) routine WHERE to_regprocedure(routine) IS NOT NULL) found
  UNION ALL
  SELECT 'retained_return_commercial_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'retained_return_commercial_nonterminal_offline',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'retained_return_commercial_source_contract',
    CASE WHEN count(*) FILTER(WHERE requirement_rows<>1 OR detail_qty<>requirement_qty)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    count(*) FILTER(WHERE requirement_rows<>1 OR detail_qty<>requirement_qty)::bigint,
    jsonb_build_object('lines',count(*),'invalidLines',count(*) FILTER(
      WHERE requirement_rows<>1 OR detail_qty<>requirement_qty))
  FROM (SELECT detail.id,detail.quantity_base detail_qty,
      count(requirement.id) requirement_rows,
      COALESCE(sum(requirement.quantity_base),0) requirement_qty
    FROM public.sales_headers sale
    JOIN public.company_sales_process_settings setting ON setting.company_id=sale.company_id
      AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
    JOIN public.sales_details detail ON detail.company_id=sale.company_id
      AND detail.sales_id=sale.id
    LEFT JOIN public.sale_stock_requirements requirement
      ON requirement.company_id=detail.company_id AND requirement.sales_detail_id=detail.id
    WHERE sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
      AND sale.document_status<>'CANCELED'
      AND (sale.document_status='POSTED' OR sale.order_runtime_status='DELIVERED')
    GROUP BY detail.id,detail.quantity_base) shape
  UNION ALL
  SELECT 'retained_return_commercial_runtime_inventory','INFO',0,
    jsonb_build_object('eligibleSources',count(*),'rule',
      'Delivered retained Retail sources remain historical and become Return sources without mode/session switch')
  FROM public.sales_headers sale
  JOIN public.company_sales_process_settings setting ON setting.company_id=sale.company_id
    AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  WHERE sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
    AND sale.document_status<>'CANCELED'
    AND (sale.document_status='POSTED' OR sale.order_runtime_status='DELIVERED')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
