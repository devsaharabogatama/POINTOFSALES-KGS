-- Read-only preflight for transactional Regular/Down Payment Draft Invoice runtime.
WITH checks AS (
  SELECT 'draft_invoice_runtime_dependency_ledger'::text check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    (2-count(*))::bigint violation_rows,
    jsonb_build_object('expected',2,'ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260909154000','20260909156000')
  UNION ALL
  SELECT 'draft_invoice_runtime_relations',CASE WHEN count(*)=8 THEN 'PASS' ELSE 'BLOCKER' END,
    (8-count(*))::bigint,jsonb_build_object('expected',8,'relationRows',count(*))
  FROM information_schema.tables WHERE table_schema='public' AND table_name IN(
    'backoffice_sales_payment_terms','backoffice_sales_payment_term_lines',
    'backoffice_sales_invoices','backoffice_sales_invoice_lines',
    'backoffice_sales_invoice_quantity_allocations','backoffice_sales_down_payment_applications',
    'backoffice_sales_invoice_receivable_schedules','backoffice_sales_invoice_audit')
  UNION ALL
  SELECT 'draft_invoice_runtime_function_dependencies',
    CASE WHEN missing_count=0 THEN 'PASS' ELSE 'BLOCKER' END,
    missing_count,jsonb_build_object('missing',missing) details
  FROM (SELECT count(*) FILTER(WHERE oid IS NULL)::bigint missing_count,
      COALESCE(jsonb_agg(signature ORDER BY signature) FILTER(WHERE oid IS NULL),'[]'::jsonb) missing
    FROM (VALUES
      ('public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)',
        to_regprocedure('public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)')),
      ('public.confirm_backoffice_sales_order(uuid,bigint,uuid)',
        to_regprocedure('public.confirm_backoffice_sales_order(uuid,bigint,uuid)')),
      ('public.dispatch_backoffice_sales_delivery(uuid,bigint,uuid,jsonb,text)',
        to_regprocedure('public.dispatch_backoffice_sales_delivery(uuid,bigint,uuid,jsonb,text)')),
      ('public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,text)',
        to_regprocedure('public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,text)')),
      ('private.acp_require_permission_capability(uuid,text,text)',
        to_regprocedure('private.acp_require_permission_capability(uuid,text,text)'))
    ) dependency(signature,oid)) dependency_state
  UNION ALL
  SELECT 'active_finance_posting_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'existing_invoice_foundation_rows',CASE WHEN row_count=0 THEN 'PASS' ELSE 'BLOCKER' END,
    row_count::bigint,jsonb_build_object('rowCount',row_count,
      'rule','Runtime cutover requires unused foundation; nonzero rows need explicit compatibility design')
  FROM (SELECT
    (SELECT count(*) FROM public.backoffice_sales_invoices)
    +(SELECT count(*) FROM public.backoffice_sales_invoice_lines)
    +(SELECT count(*) FROM public.backoffice_sales_invoice_quantity_allocations)
    +(SELECT count(*) FROM public.backoffice_sales_down_payment_applications)
    +(SELECT count(*) FROM public.backoffice_sales_invoice_receivable_schedules)
    +(SELECT count(*) FROM public.backoffice_sales_invoice_audit) row_count) tally
  UNION ALL
  SELECT 'invoiceable_quantity_ledger_integrity',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_order_lines line
  WHERE line.accepted_base_qty<0 OR line.returned_before_invoice_base_qty<0
    OR line.draft_invoice_allocated_base_qty<0 OR line.invoiced_base_qty<0
    OR line.to_invoice_base_qty<0
    OR line.draft_invoice_allocated_base_qty+line.invoiced_base_qty>line.net_delivered_base_qty
  UNION ALL
  SELECT 'invoiceable_order_state_integrity',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_order_lines line
  JOIN public.backoffice_sales_orders document
    ON document.company_id=line.company_id AND document.id=line.sales_order_id
  WHERE line.to_invoice_base_qty>0
    AND (document.status<>'CONFIRMED'
      OR document.sales_origin<>'BACKOFFICE_SALES'
      OR document.sales_process_mode<>'BACKOFFICE_DELIVERED_QTY_INVOICE')
  UNION ALL
  SELECT 'invoiceable_commercial_snapshot_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_order_lines line
  WHERE line.to_invoice_base_qty>0 AND (
    line.base_qty_per_uom<=0 OR line.canonical_unit_price<0
    OR line.line_discount_amount<0 OR line.allocated_order_discount_amount<0
    OR line.tax_amount<0 OR line.tax_base<0
    OR jsonb_typeof(line.pricing_snapshot)<>'object')
), inventory AS (
  SELECT 'draft_invoice_runtime_inventory'::text check_name,'INFO'::text status,
    0::bigint violation_rows,jsonb_build_object(
      'confirmedOrders',(SELECT count(*) FROM public.backoffice_sales_orders WHERE status='CONFIRMED'),
      'invoiceableOrders',(SELECT count(DISTINCT sales_order_id)
        FROM public.backoffice_sales_order_lines WHERE to_invoice_base_qty>0),
      'invoiceableLines',(SELECT count(*) FROM public.backoffice_sales_order_lines
        WHERE to_invoice_base_qty>0),
      'invoiceableBaseQty',(SELECT COALESCE(sum(to_invoice_base_qty),0)
        FROM public.backoffice_sales_order_lines),
      'paymentTerms',(SELECT count(*) FROM public.backoffice_sales_payment_terms),
      'taxedInvoiceableLines',(SELECT count(*) FROM public.backoffice_sales_order_lines
        WHERE to_invoice_base_qty>0 AND tax_rule_id IS NOT NULL),
      'downPaymentAccountCompanies',(SELECT count(DISTINCT company_id)
        FROM public.chart_of_accounts WHERE system_function_key='CUSTOMER_ADVANCE_LIABILITY'
          AND is_active AND is_postable)) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) output
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
