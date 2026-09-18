-- SELECT-only Production preflight for the retained Retail -> Backoffice Return
-- compatibility repair. Run the entire file. This file performs no writes.
WITH
dependency_versions(version) AS (VALUES
  ('20260829110000'), -- Retail Return/ODR compatibility
  ('20260911130000'), -- Sales-process atomic Apply
  ('20260916110000'), -- Office Retail history reader
  ('20260917110000'), -- Backoffice Return commercial foundation
  ('20260917120000'), -- Customer Return Receipt
  ('20260917121000'), -- receipt immutability fix
  ('20260917122000'), -- receipt audit guard fix
  ('20260917130000'), -- Credit Note foundation
  ('20260917131000'), -- Credit Note runtime
  ('20260917150000'), -- Customer Refund
  ('20260917151000'), -- Refund reversal guard
  ('20260918100000')  -- Backoffice Return UI/read models
),
missing_dependencies AS (
  SELECT array_agg(required.version ORDER BY required.version) AS versions
  FROM dependency_versions required
  LEFT JOIN private.kgs_schema_migrations installed
    ON installed.version=required.version
  WHERE installed.version IS NULL
),
expected_relations(name) AS (VALUES
  ('retained_retail_backoffice_returns'),
  ('retained_retail_backoffice_return_lines'),
  ('retained_retail_backoffice_return_receipts'),
  ('retained_retail_backoffice_return_receipt_lines'),
  ('retained_retail_backoffice_credit_notes'),
  ('retained_retail_backoffice_credit_note_lines'),
  ('retained_retail_backoffice_refunds'),
  ('retained_retail_backoffice_return_operations'),
  ('retained_retail_backoffice_return_audit')
),
relation_collisions AS (
  SELECT array_agg(name ORDER BY name) FILTER (
    WHERE to_regclass(format('public.%I',name)) IS NOT NULL
  ) AS names FROM expected_relations
),
expected_routines(signature) AS (VALUES
  ('public.get_retained_retail_backoffice_return_source(uuid)'),
  ('public.save_retained_retail_backoffice_return_draft(uuid,bigint,uuid,uuid,jsonb)'),
  ('public.submit_retained_retail_backoffice_return(uuid,bigint,uuid)'),
  ('public.approve_retained_retail_backoffice_return(uuid,bigint,uuid)'),
  ('public.post_retained_retail_backoffice_return_receipt(uuid,bigint,uuid,date,jsonb,text)'),
  ('public.allocate_retained_retail_backoffice_return_credit(uuid,bigint,uuid,jsonb)'),
  ('public.post_retained_retail_backoffice_refund(uuid,bigint,uuid,uuid,numeric,text)')
),
routine_collisions AS (
  SELECT array_agg(signature ORDER BY signature) FILTER (
    WHERE to_regprocedure(signature) IS NOT NULL
  ) AS signatures FROM expected_routines
),
retained AS (
  SELECT sale.company_id,sale.id sales_id,sale.document_status,
    sale.order_runtime_status,sale.paid_amount,sale.grand_total_after_rounding,
    EXISTS(SELECT 1 FROM public.sales_invoice_snapshots snapshot
      WHERE snapshot.company_id=sale.company_id AND snapshot.sales_id=sale.id) has_invoice,
    EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
      WHERE delivery.company_id=sale.company_id AND delivery.sales_id=sale.id
        AND delivery.status='DELIVERED') has_delivered_document
  FROM public.sales_headers sale
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=sale.company_id
   AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  WHERE sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
    AND sale.document_status<>'CANCELED'
    AND (sale.document_status='POSTED'
      OR sale.order_runtime_status='DELIVERED'
      OR EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
        WHERE delivery.company_id=sale.company_id AND delivery.sales_id=sale.id
          AND delivery.status='DELIVERED'))
    AND NOT EXISTS(
      SELECT 1
      FROM public.sales_process_cutover_items item
      JOIN public.sales_process_cutover_audit audit
        ON audit.company_id=item.company_id AND audit.cutover_item_id=item.id
      WHERE item.company_id=sale.company_id
        AND item.source_document_id=sale.id
        AND item.source_document_type='RETAIL_SALE'
        AND audit.action='APPLY_ITEM'
        AND audit.after_state->'converterResult'->>'targetDocumentType'=
          'BACKOFFICE_SALES_ORDER'
        AND nullif(audit.after_state->'converterResult'->>'targetDocumentId','')
          IS NOT NULL)
),
line_inventory AS (
  SELECT retained.company_id,retained.sales_id,detail.id sales_detail_id,
    private.odr6d_returnable_sales_detail_quantity(
      retained.company_id,detail.id) received_qty,
    COALESCE((SELECT sum(return_line.quantity_uom)
      FROM public.sales_return_lines return_line
      JOIN public.sales_return_documents return_document
        ON return_document.company_id=return_line.company_id
       AND return_document.id=return_line.document_id
       AND return_document.status='POSTED'
      WHERE return_line.company_id=detail.company_id
        AND return_line.source_sales_detail_id=detail.id),0) retail_returned_qty,
    COALESCE((SELECT sum(allocation.quantity_base)
      FROM public.sale_fifo_allocations allocation
      WHERE allocation.company_id=detail.company_id
        AND allocation.sales_detail_id=detail.id),0) fifo_allocated_base_qty,
    detail.uom_factor_to_base_snapshot
  FROM retained
  JOIN public.sales_details detail
    ON detail.company_id=retained.company_id AND detail.sales_id=retained.sales_id
),
eligible_lines AS (
  SELECT *,received_qty-retail_returned_qty remaining_qty
  FROM line_inventory WHERE received_qty>retail_returned_qty
),
checks AS (
  SELECT 'retained_return_dependency_ledger' check_name,
    CASE WHEN COALESCE(cardinality(versions),0)=0 THEN 'PASS' ELSE 'BLOCKER' END status,
    COALESCE(cardinality(versions),0)::bigint violation_rows,
    jsonb_build_object('missing',COALESCE(to_jsonb(versions),'[]'::jsonb),
      'expected',(SELECT count(*) FROM dependency_versions)) details
  FROM missing_dependencies
  UNION ALL
  SELECT 'retained_return_relation_collision',
    CASE WHEN COALESCE(cardinality(names),0)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    COALESCE(cardinality(names),0)::bigint,
    jsonb_build_object('existing',COALESCE(to_jsonb(names),'[]'::jsonb))
  FROM relation_collisions
  UNION ALL
  SELECT 'retained_return_routine_collision',
    CASE WHEN COALESCE(cardinality(signatures),0)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    COALESCE(cardinality(signatures),0)::bigint,
    jsonb_build_object('existing',COALESCE(to_jsonb(signatures),'[]'::jsonb))
  FROM routine_collisions
  UNION ALL
  SELECT 'retained_return_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'retained_return_nonterminal_offline',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'retained_return_source_line_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidLines',count(*),
      'rule','Positive received quantity requires Product/UOM/factor source')
  FROM eligible_lines line
  JOIN public.sales_details detail
    ON detail.company_id=line.company_id AND detail.id=line.sales_detail_id
  WHERE detail.product_id IS NULL OR detail.sale_uom_id IS NULL
    OR line.uom_factor_to_base_snapshot IS NULL
    OR line.uom_factor_to_base_snapshot<=0
  UNION ALL
  SELECT 'retained_return_invoice_boundary','INFO',0,
    jsonb_build_object('withInvoice',count(*) FILTER(WHERE has_invoice),
      'withoutInvoice',count(*) FILTER(WHERE NOT has_invoice),
      'rule','No Invoice is not guessed; financial correction waits for explicit source')
  FROM retained
  UNION ALL
  SELECT 'retained_return_fifo_inventory','INFO',0,
    jsonb_build_object(
      'returnableLines',(SELECT count(*) FROM eligible_lines),
      'linesWithoutFifo',count(*) FILTER(WHERE fifo_allocated_base_qty<=0),
      'rule','Physical RESTOCK/DESTROY must preserve exact original FIFO lineage')
  FROM eligible_lines
  UNION ALL
  SELECT 'retained_return_payment_inventory','INFO',0,
    jsonb_build_object(
      'unpaid',count(*) FILTER(WHERE paid_amount<=0),
      'partial',count(*) FILTER(WHERE paid_amount>0
        AND paid_amount<grand_total_after_rounding),
      'paid',count(*) FILTER(WHERE paid_amount>=grand_total_after_rounding),
      'rule','Credit reduces AR first; only excess payment becomes refund liability')
  FROM retained
  UNION ALL
  SELECT 'retained_return_runtime_inventory','INFO',0,
    jsonb_build_object('sources',(SELECT count(*) FROM retained),
      'legacyPosted',(SELECT count(*) FROM retained WHERE document_status='POSTED'),
      'delivered',(SELECT count(*) FROM retained WHERE order_runtime_status='DELIVERED'
        OR has_delivered_document),
      'returnableLines',(SELECT count(*) FROM eligible_lines),
      'priorRetailReturnQty',COALESCE((SELECT sum(retail_returned_qty)
        FROM line_inventory),0))
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1
  WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
