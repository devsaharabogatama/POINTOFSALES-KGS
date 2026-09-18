-- SELECT-only preflight for retained Retail physical Return receipt.
WITH checks AS (
 SELECT 'retained_receipt_dependency_ledger' check_name,
  CASE WHEN count(*)=8 THEN 'PASS' ELSE 'BLOCKER' END status,
  (8-count(*))::bigint violation_rows,jsonb_build_object('present',count(*),'expected',8) details
 FROM private.kgs_schema_migrations WHERE version IN('20260917110000','20260917120000',
  '20260917121000','20260917122000','20260917140000','20260918100000',
  '20260918110000','20260918120000')
 UNION ALL
 SELECT 'retained_receipt_column_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  count(*)::bigint,jsonb_build_object('existing',COALESCE(jsonb_agg(column_name),'[]'::jsonb))
 FROM information_schema.columns WHERE table_schema='public'
  AND table_name='backoffice_sales_return_receipt_fifo_restorations'
  AND column_name IN('cost_lineage','source_retail_sales_detail_id','source_stock_requirement_id',
    'source_line_base_qty','source_line_cost_total')
 UNION ALL
 SELECT 'retained_receipt_routine_collision',
  CASE WHEN to_regprocedure('private.post_retained_retail_return_receipt_core(uuid,bigint,uuid,date,jsonb,text)') IS NULL
    THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN to_regprocedure('private.post_retained_retail_return_receipt_core(uuid,bigint,uuid,date,jsonb,text)') IS NULL
    THEN 0 ELSE 1 END,jsonb_build_object('existing',to_regprocedure(
      'private.post_retained_retail_return_receipt_core(uuid,bigint,uuid,date,jsonb,text)') IS NOT NULL)
 UNION ALL
 SELECT 'retained_receipt_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  count(*)::bigint,jsonb_build_object('runRows',count(*)) FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
 UNION ALL
 SELECT 'retained_receipt_nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  count(*)::bigint,jsonb_build_object('submissionRows',count(*)) FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
 UNION ALL
 SELECT 'retained_receipt_legacy_cost_contract',
  CASE WHEN count(*) FILTER(WHERE requirement_rows<>1 OR stock_product_mismatch_rows<>0
    OR detail_cost<0 OR detail_qty<=0)=0
    THEN 'PASS' ELSE 'BLOCKER' END,
  count(*) FILTER(WHERE requirement_rows<>1 OR stock_product_mismatch_rows<>0
    OR detail_cost<0 OR detail_qty<=0)::bigint,
  jsonb_build_object('lines',count(*),'invalidLines',count(*) FILTER(
    WHERE requirement_rows<>1 OR stock_product_mismatch_rows<>0 OR detail_cost<0 OR detail_qty<=0),
    'productIdentityMismatchLines',count(*) FILTER(WHERE stock_product_mismatch_rows<>0),
    'rule','One physical stock requirement whose stock Product equals the commercial Product')
 FROM (SELECT detail.id,detail.fifo_cost_total detail_cost,detail.quantity_base detail_qty,
   count(requirement.id) requirement_rows,count(requirement.id) FILTER(
    WHERE requirement.stock_product_id IS DISTINCT FROM detail.product_id
      OR requirement.commercial_product_id IS DISTINCT FROM detail.product_id)
    stock_product_mismatch_rows
  FROM public.sales_headers sale JOIN public.company_sales_process_settings setting
   ON setting.company_id=sale.company_id AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  JOIN public.sales_details detail ON detail.company_id=sale.company_id AND detail.sales_id=sale.id
  LEFT JOIN public.sale_stock_requirements requirement
   ON requirement.company_id=detail.company_id AND requirement.sales_detail_id=detail.id
  WHERE sale.sales_process_mode='RETAIL_CONFIRM_INVOICE' AND sale.document_status<>'CANCELED'
   AND (sale.document_status='POSTED' OR sale.order_runtime_status='DELIVERED'
    OR EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
      WHERE delivery.company_id=sale.company_id AND delivery.sales_id=sale.id
        AND delivery.status='DELIVERED'))
   AND NOT EXISTS(SELECT 1 FROM public.sales_process_cutover_items item
    JOIN public.sales_process_cutover_audit audit
      ON audit.company_id=item.company_id AND audit.cutover_item_id=item.id
    WHERE item.company_id=sale.company_id AND item.source_document_id=sale.id
      AND item.source_document_type='RETAIL_SALE' AND audit.action='APPLY_ITEM'
      AND audit.after_state->'converterResult'->>'targetDocumentType'='BACKOFFICE_SALES_ORDER'
      AND nullif(audit.after_state->'converterResult'->>'targetDocumentId','') IS NOT NULL)
  GROUP BY detail.id,detail.fifo_cost_total,detail.quantity_base) qualified
)
SELECT * FROM checks ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
