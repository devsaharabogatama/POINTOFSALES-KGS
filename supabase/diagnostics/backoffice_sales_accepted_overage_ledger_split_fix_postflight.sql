-- SELECT-only postflight for accepted-overage ledger split forward-fix 20260912137000.
WITH resolver AS (
  SELECT proc.oid,proc.prosecdef,proc.proconfig,pg_get_functiondef(proc.oid) body
  FROM pg_proc proc WHERE proc.oid=to_regprocedure(
    'private.resolve_backoffice_sales_overage_wrong_item_core(uuid,bigint,uuid,date,text)')
), overage_by_order_line AS (
  SELECT discrepancy.company_id,discrepancy.sales_order_line_id,
    round(sum(discrepancy.accepted_overage_base_qty),6) accepted_overage_base_qty
  FROM public.backoffice_sales_delivery_discrepancy_lines discrepancy
  WHERE discrepancy.accepted_overage_base_qty>0
  GROUP BY discrepancy.company_id,discrepancy.sales_order_line_id
), checks AS (
  SELECT 'overage_split_migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260912137000'
  UNION ALL SELECT 'overage_split_resolver_definition_contract',
    CASE WHEN count(*)=1 AND bool_and(
      position('approved_overage_base_qty=approved_overage_base_qty+v_qty' in body)>0
      AND position('accepted_base_qty=accepted_base_qty+v_qty' in body)=0)
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(
      position('approved_overage_base_qty=approved_overage_base_qty+v_qty' in body)>0
      AND position('accepted_base_qty=accepted_base_qty+v_qty' in body)=0)
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('routineRows',count(*),'regularAcceptedIncrementPresent',
      COALESCE(bool_or(position('accepted_base_qty=accepted_base_qty+v_qty' in body)>0),false))
  FROM resolver
  UNION ALL SELECT 'overage_split_resolver_security_contract',
    CASE WHEN count(*)=1 AND bool_and(prosecdef
      AND proconfig @> ARRAY['search_path=public, pg_temp']
      AND proconfig @> ARRAY['statement_timeout=30s']) THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(prosecdef
      AND proconfig @> ARRAY['search_path=public, pg_temp']
      AND proconfig @> ARRAY['statement_timeout=30s']) THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('routineRows',count(*),'securityDefiner',
      COALESCE(bool_and(prosecdef),false),'config',min(proconfig::text)) FROM resolver
  UNION ALL SELECT 'overage_split_private_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('browserExecutableRows',count(*))
  FROM resolver WHERE has_function_privilege('anon',oid,'EXECUTE')
    OR has_function_privilege('authenticated',oid,'EXECUTE')
  UNION ALL SELECT 'overage_split_quantity_constraint_contract',
    CASE WHEN count(*)=1 AND bool_and(
      position('approved_overage_base_qty >= (0)::numeric' in definition)>0
      AND position('accepted_base_qty <= ordered_base_qty' in definition)>0
      AND position('ordered_base_qty + approved_overage_base_qty' in definition)=0
      AND position('approved_overage_base_qty <= accepted_base_qty' in definition)=0)
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(
      position('approved_overage_base_qty >= (0)::numeric' in definition)>0
      AND position('accepted_base_qty <= ordered_base_qty' in definition)>0
      AND position('ordered_base_qty + approved_overage_base_qty' in definition)=0
      AND position('approved_overage_base_qty <= accepted_base_qty' in definition)=0)
      THEN 0 ELSE 1 END::bigint,jsonb_build_object('constraintRows',count(*),
        'definition',min(definition))
  FROM (SELECT pg_get_constraintdef(constraint_state.oid) definition
    FROM pg_constraint constraint_state
    WHERE constraint_state.conrelid='public.backoffice_sales_order_lines'::regclass
      AND constraint_state.conname='backoffice_sales_order_lines_invoiceable_quantity_check') c
  UNION ALL SELECT 'overage_split_source_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_order_lines line
  FULL JOIN overage_by_order_line overage ON overage.company_id=line.company_id
    AND overage.sales_order_line_id=line.id
  WHERE line.id IS NULL
    OR COALESCE(line.approved_overage_base_qty,0)<>COALESCE(overage.accepted_overage_base_qty,0)
  UNION ALL SELECT 'overage_split_regular_quantity_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_order_lines line
  WHERE line.accepted_base_qty<0 OR line.accepted_base_qty>line.ordered_base_qty
    OR line.returned_before_invoice_base_qty>line.accepted_base_qty
    OR line.draft_invoice_allocated_base_qty+line.invoiced_base_qty
      >line.accepted_base_qty-line.returned_before_invoice_base_qty
  UNION ALL SELECT 'overage_split_invoice_reader_contract',
    CASE WHEN count(*)=1 AND bool_and(
      position('sum(line.to_invoice_base_qty)' in body)>0
      AND position('sum(discrepancy.overage_to_invoice_base_qty)' in body)>0)
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(
      position('sum(line.to_invoice_base_qty)' in body)>0
      AND position('sum(discrepancy.overage_to_invoice_base_qty)' in body)>0)
      THEN 0 ELSE 1 END::bigint,jsonb_build_object('routineRows',count(*))
  FROM (SELECT pg_get_functiondef(to_regprocedure(
    'public.get_backoffice_sales_invoice_workspace(uuid,text,text,integer)')) body) reader
  UNION ALL SELECT 'overage_split_runtime_inventory','INFO',0,
    jsonb_build_object('acceptedOverageOrderLines',count(*),
      'acceptedOverageBaseQty',COALESCE(sum(overage.accepted_overage_base_qty),0),
      'regularAcceptedBaseQty',COALESCE(sum(line.accepted_base_qty),0),
      'regularToInvoiceBaseQty',COALESCE(sum(line.to_invoice_base_qty),0))
  FROM overage_by_order_line overage
  JOIN public.backoffice_sales_order_lines line ON line.company_id=overage.company_id
    AND line.id=overage.sales_order_line_id
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY
  CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

