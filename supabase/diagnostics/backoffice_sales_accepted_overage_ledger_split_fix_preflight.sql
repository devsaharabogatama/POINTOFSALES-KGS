-- SELECT-only preflight for accepted-overage ledger split forward-fix 20260912137000.
WITH resolver AS (
  SELECT pg_get_functiondef(to_regprocedure(
    'private.resolve_backoffice_sales_overage_wrong_item_core(uuid,bigint,uuid,date,text)')) body
), overage_by_order_line AS (
  SELECT discrepancy.company_id,discrepancy.sales_order_line_id,
    round(sum(discrepancy.accepted_overage_base_qty),6) accepted_overage_base_qty
  FROM public.backoffice_sales_delivery_discrepancy_lines discrepancy
  WHERE discrepancy.accepted_overage_base_qty>0
  GROUP BY discrepancy.company_id,discrepancy.sales_order_line_id
), reconciliation AS (
  SELECT line.company_id,line.id,line.sales_order_id,line.ordered_base_qty,
    line.accepted_base_qty,line.returned_before_invoice_base_qty,
    line.draft_invoice_allocated_base_qty,line.invoiced_base_qty,
    line.approved_overage_base_qty,
    COALESCE(overage.accepted_overage_base_qty,0) discrepancy_overage_base_qty,
    round(line.accepted_base_qty-COALESCE(overage.accepted_overage_base_qty,0),6)
      corrected_regular_accepted_base_qty
  FROM public.backoffice_sales_order_lines line
  LEFT JOIN overage_by_order_line overage
    ON overage.company_id=line.company_id AND overage.sales_order_line_id=line.id
  WHERE line.approved_overage_base_qty<>0
    OR COALESCE(overage.accepted_overage_base_qty,0)<>0
), facts AS (
  SELECT
    (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260912123000','20260912124000','20260912125000',
        '20260912130000','20260912132000','20260912136000')) dependency_rows,
    (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20260912137000') migration_rows,
    (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) active_finance,
    (SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) offline_rows,
    (SELECT pg_get_constraintdef(constraint_state.oid)
      FROM pg_constraint constraint_state
      WHERE constraint_state.conrelid='public.backoffice_sales_order_lines'::regclass
        AND constraint_state.conname='backoffice_sales_order_lines_invoiceable_quantity_check')
      quantity_constraint
), checks AS (
  SELECT 'overage_split_dependency_ledger' check_name,
    CASE WHEN dependency_rows=6 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(dependency_rows-6)::bigint violation_rows,
    jsonb_build_object('present',dependency_rows,'expected',6) details FROM facts
  UNION ALL SELECT 'overage_split_migration_collision',
    CASE WHEN migration_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
    migration_rows::bigint,jsonb_build_object('ledgerRows',migration_rows) FROM facts
  UNION ALL SELECT 'overage_split_active_finance_queue',
    CASE WHEN active_finance=0 THEN 'PASS' ELSE 'BLOCKER' END,
    active_finance::bigint,jsonb_build_object('runRows',active_finance) FROM facts
  UNION ALL SELECT 'overage_split_nonterminal_offline',
    CASE WHEN offline_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
    offline_rows::bigint,jsonb_build_object('submissionRows',offline_rows) FROM facts
  UNION ALL SELECT 'overage_split_resolver_anchor_contract',
    CASE WHEN body IS NOT NULL
      AND (length(body)-length(replace(body,
        'accepted_base_qty=accepted_base_qty+v_qty,updated_at=v_now','')))
        /length('accepted_base_qty=accepted_base_qty+v_qty,updated_at=v_now')=1
      AND position('approved_overage_base_qty=approved_overage_base_qty+v_qty' in body)>0
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN body IS NOT NULL
      AND (length(body)-length(replace(body,
        'accepted_base_qty=accepted_base_qty+v_qty,updated_at=v_now','')))
        /length('accepted_base_qty=accepted_base_qty+v_qty,updated_at=v_now')=1
      AND position('approved_overage_base_qty=approved_overage_base_qty+v_qty' in body)>0
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('resolverExists',body IS NOT NULL,
      'legacyIncrementCount',CASE WHEN body IS NULL THEN 0 ELSE
        (length(body)-length(replace(body,
          'accepted_base_qty=accepted_base_qty+v_qty,updated_at=v_now','')))
          /length('accepted_base_qty=accepted_base_qty+v_qty,updated_at=v_now') END)
  FROM resolver
  UNION ALL SELECT 'overage_split_legacy_constraint_contract',
    CASE WHEN quantity_constraint IS NOT NULL
      AND position('approved_overage_base_qty <= accepted_base_qty' in quantity_constraint)>0
      AND position('accepted_base_qty <= (ordered_base_qty + approved_overage_base_qty)' in quantity_constraint)>0
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN quantity_constraint IS NOT NULL
      AND position('approved_overage_base_qty <= accepted_base_qty' in quantity_constraint)>0
      AND position('accepted_base_qty <= (ordered_base_qty + approved_overage_base_qty)' in quantity_constraint)>0
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('constraint',quantity_constraint) FROM facts
  UNION ALL SELECT 'overage_split_source_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*),'orderLineIds',
      COALESCE(jsonb_agg(id ORDER BY id),'[]'::jsonb))
  FROM reconciliation
  WHERE approved_overage_base_qty<>discrepancy_overage_base_qty
  UNION ALL SELECT 'overage_split_regular_quantity_backfill_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*),'orderLineIds',
      COALESCE(jsonb_agg(id ORDER BY id),'[]'::jsonb),
      'rule','No historical regular Draft/Posted allocation may have consumed accepted overage')
  FROM reconciliation
  WHERE corrected_regular_accepted_base_qty<0
    OR corrected_regular_accepted_base_qty>ordered_base_qty
    OR returned_before_invoice_base_qty>corrected_regular_accepted_base_qty
    OR draft_invoice_allocated_base_qty+invoiced_base_qty
      >corrected_regular_accepted_base_qty-returned_before_invoice_base_qty
  UNION ALL SELECT 'overage_split_runtime_inventory','INFO',0,
    jsonb_build_object('affectedOrderLines',count(*),
      'acceptedOverageBaseQty',COALESCE(sum(discrepancy_overage_base_qty),0),
      'regularDraftAllocatedBaseQty',COALESCE(sum(draft_invoice_allocated_base_qty),0),
      'regularInvoicedBaseQty',COALESCE(sum(invoiced_base_qty),0))
  FROM reconciliation
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY
  CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

