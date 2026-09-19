-- SELECT-only preflight for 20260919100000.
WITH checks AS (
  SELECT 'return_net_dependency_ledger' check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    (2-count(*))::bigint violation_rows,
    jsonb_build_object('required',ARRAY['20260918150000','20260918160000'],
      'installed',COALESCE(jsonb_agg(version ORDER BY version),'[]'::jsonb)) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260918150000','20260918160000')
  UNION ALL
  SELECT 'return_net_routine_collision',
    CASE WHEN to_regprocedure('public.get_sales_return_commercial_adjustments()')
      IS NULL THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN to_regprocedure('public.get_sales_return_commercial_adjustments()')
      IS NULL THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('existing',to_regprocedure(
      'public.get_sales_return_commercial_adjustments()')::text)
  UNION ALL
  SELECT 'return_net_source_line_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_return_lines line
  WHERE (line.source_kind='BACKOFFICE')<>(line.sales_order_line_id IS NOT NULL)
     OR (line.source_kind='RETAINED_RETAIL')<>(line.retail_sales_detail_id IS NOT NULL)
  UNION ALL
  SELECT 'return_net_receipt_stock_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*),'rule',
      'RESTOCK has movement; DESTROY has no movement and no stock increase')
  FROM public.backoffice_sales_return_receipt_lines line
  WHERE (line.disposition='RESTOCK')<>(line.stock_movement_id IS NOT NULL)
     OR line.disposition NOT IN('RESTOCK','DESTROY')
  UNION ALL
  SELECT 'return_net_credit_source_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_credit_note_lines line
  WHERE (line.source_kind='BACKOFFICE')<>(line.sales_order_line_id IS NOT NULL)
     OR (line.source_kind='RETAINED_RETAIL')<>(line.source_retail_sales_detail_id IS NOT NULL)
  UNION ALL
  SELECT 'return_net_runtime_inventory','INFO',0::bigint,
    jsonb_build_object(
      'postedReturnReceipts',(SELECT count(*) FROM public.backoffice_sales_return_receipts),
      'receivedReturnLines',(SELECT count(*) FROM public.backoffice_sales_return_receipt_lines),
      'restockLines',(SELECT count(*) FROM public.backoffice_sales_return_receipt_lines WHERE disposition='RESTOCK'),
      'destroyLines',(SELECT count(*) FROM public.backoffice_sales_return_receipt_lines WHERE disposition='DESTROY'),
      'postedCreditNotes',(SELECT count(*) FROM public.backoffice_sales_credit_notes WHERE status='POSTED'))
)
SELECT * FROM checks ORDER BY status,check_name;
