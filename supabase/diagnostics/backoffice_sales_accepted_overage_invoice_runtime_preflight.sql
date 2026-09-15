-- SELECT-only preflight for Step 4/6.5C2B. Run the entire file.
WITH checks AS (
  SELECT 'c2b_dependency_ledger' check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(2-count(*))::bigint violation_rows,
    jsonb_build_object('expected',2,'present',count(*)) details
  FROM private.kgs_schema_migrations WHERE version IN('20260912122000','20260912123000')
  UNION ALL
  SELECT 'c2b_runtime_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('existing',COALESCE(jsonb_agg(p.oid::regprocedure::text),'[]'::jsonb))
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='private' AND p.proname IN(
    'trg_backoffice_sales_invoice_overage_counter',
    'trg_backoffice_sales_invoice_accepted_overage_lines')
  UNION ALL
  SELECT 'c2b_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('runRows',count(*)) FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'c2b_nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('submissionRows',count(*)) FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'c2b_canonical_call_chain',CASE WHEN count(*)=5 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(5-count(*))::bigint,jsonb_build_object('expected',5,'present',count(*))
  FROM (VALUES
    (to_regprocedure('private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(uuid,bigint,uuid,uuid,jsonb)')),
    (to_regprocedure('private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)')),
    (to_regprocedure('public.cancel_backoffice_sales_invoice_draft(uuid,bigint,uuid,text)')),
    (to_regprocedure('public.post_backoffice_sales_invoice(uuid,bigint,uuid)')),
    (to_regprocedure('private.validate_backoffice_sales_invoice_overage_source()'))
  ) required(oid) WHERE oid IS NOT NULL
  UNION ALL
  SELECT 'c2b_existing_overage_counter_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
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
  SELECT 'c2b_runtime_inventory','INFO',0,
    jsonb_build_object('resolvedAcceptedOverage',count(*),
      'invoiceableBaseQty',COALESCE(sum(overage_to_invoice_base_qty),0))
  FROM public.backoffice_sales_delivery_discrepancy_lines
  WHERE requested_resolution='ACCEPT_OVERAGE' AND commercial_approval_status='APPROVED'
    AND warehouse_resolution_status='RESOLVED'
)
SELECT * FROM checks ORDER BY
  CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
