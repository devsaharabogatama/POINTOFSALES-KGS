-- BEGIN_FULL_POSTFLIGHT_20260917122000
-- SELECT-only verification for 20260917120000, 20260917121000 and 20260917122000.
-- Run the entire file, including the final SELECT.
WITH immutable_triggers AS (
  SELECT expected.table_name,expected.trigger_name,trigger_state.oid AS trigger_oid,
    trigger_state.tgenabled,
    trigger_state.tgfoid=to_regprocedure(expected.guard_signature) AS uses_canonical_guard
  FROM (VALUES
    ('backoffice_sales_return_receipts','backoffice_sales_return_receipts_immutable',
      'private.trg_guard_backoffice_sales_return_receipt_history()'),
    ('backoffice_sales_return_receipt_lines','backoffice_sales_return_receipt_lines_immutable',
      'private.trg_reject_backoffice_sales_return_receipt_history_mutation()'),
    ('backoffice_sales_return_receipt_fifo_restorations','backoffice_sales_return_receipt_fifo_immutable',
      'private.trg_reject_backoffice_sales_return_receipt_history_mutation()'),
    ('backoffice_sales_return_receipt_operations','backoffice_sales_return_receipt_operations_immutable',
      'private.trg_reject_backoffice_sales_return_receipt_history_mutation()'),
    ('backoffice_sales_return_receipt_audit','backoffice_sales_return_receipt_audit_immutable',
      'private.trg_reject_backoffice_sales_return_receipt_history_mutation()')
  ) expected(table_name,trigger_name,guard_signature)
  LEFT JOIN pg_trigger trigger_state
    ON trigger_state.tgrelid=to_regclass('public.'||expected.table_name)
   AND trigger_state.tgname=expected.trigger_name
   AND NOT trigger_state.tgisinternal
), checks AS (
  SELECT 'customer_return_receipt_audit_guard_fix_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260917122000'
  UNION ALL
  SELECT 'customer_return_receipt_immutability_fix_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260917121000'
  UNION ALL
  SELECT 'customer_return_receipt_migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260917120000'
  UNION ALL
  SELECT 'customer_return_receipt_required_relations',
    CASE WHEN count(*)=5 THEN 'PASS' ELSE 'BLOCKER' END,(5-count(*))::bigint,
    jsonb_build_object('present',count(*),'expected',5)
  FROM (VALUES('backoffice_sales_return_receipts'),('backoffice_sales_return_receipt_lines'),
    ('backoffice_sales_return_receipt_fifo_restorations'),
    ('backoffice_sales_return_receipt_operations'),('backoffice_sales_return_receipt_audit')) candidate(name)
  WHERE to_regclass('public.'||candidate.name) IS NOT NULL
  UNION ALL
  SELECT 'customer_return_receipt_required_routines',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,(3-count(*))::bigint,
    jsonb_build_object('present',count(*),'expected',3)
  FROM (VALUES('private.backoffice_sales_return_receipt_operation_retry(uuid,uuid,text)'),
    ('private.post_backoffice_sales_return_receipt_core(uuid,bigint,uuid,date,jsonb,text)'),
    ('public.post_backoffice_sales_return_receipt(uuid,bigint,uuid,date,jsonb,text)')) candidate(signature)
  WHERE to_regprocedure(candidate.signature) IS NOT NULL
  UNION ALL
  SELECT 'customer_return_receipt_security_contract',
    CASE WHEN (SELECT count(*) FROM pg_class relation
        JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
        WHERE namespace.nspname='public' AND relation.relname IN(
          'backoffice_sales_return_receipts','backoffice_sales_return_receipt_lines',
          'backoffice_sales_return_receipt_fifo_restorations',
          'backoffice_sales_return_receipt_operations','backoffice_sales_return_receipt_audit')
          AND relation.relrowsecurity)=5
      AND NOT has_function_privilege('authenticated',
        'private.post_backoffice_sales_return_receipt_core(uuid,bigint,uuid,date,jsonb,text)','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.post_backoffice_sales_return_receipt(uuid,bigint,uuid,date,jsonb,text)','EXECUTE')
      AND NOT has_function_privilege('anon',
        'public.post_backoffice_sales_return_receipt(uuid,bigint,uuid,date,jsonb,text)','EXECUTE')
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN (SELECT count(*) FROM pg_class relation
        JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
        WHERE namespace.nspname='public' AND relation.relname IN(
          'backoffice_sales_return_receipts','backoffice_sales_return_receipt_lines',
          'backoffice_sales_return_receipt_fifo_restorations',
          'backoffice_sales_return_receipt_operations','backoffice_sales_return_receipt_audit')
          AND relation.relrowsecurity)=5
      AND NOT has_function_privilege('authenticated',
        'private.post_backoffice_sales_return_receipt_core(uuid,bigint,uuid,date,jsonb,text)','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.post_backoffice_sales_return_receipt(uuid,bigint,uuid,date,jsonb,text)','EXECUTE')
      AND NOT has_function_privilege('anon',
        'public.post_backoffice_sales_return_receipt(uuid,bigint,uuid,date,jsonb,text)','EXECUTE')
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('rlsTables',(SELECT count(*) FROM pg_class relation
      JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
      WHERE namespace.nspname='public' AND relation.relname IN(
        'backoffice_sales_return_receipts','backoffice_sales_return_receipt_lines',
        'backoffice_sales_return_receipt_fifo_restorations',
        'backoffice_sales_return_receipt_operations','backoffice_sales_return_receipt_audit')
        AND relation.relrowsecurity),'expectedRlsTables',5)
  UNION ALL
  SELECT 'customer_return_receipt_immutable_trigger_contract',
    CASE WHEN count(trigger_oid)=5
      AND count(*) FILTER (WHERE tgenabled='A' AND uses_canonical_guard)=5
      THEN 'PASS' ELSE 'BLOCKER' END,
    (5-LEAST(count(*) FILTER (WHERE tgenabled='A' AND uses_canonical_guard),5))::bigint,
    jsonb_build_object('present',count(trigger_oid),
      'enabledAlways',count(*) FILTER (WHERE tgenabled='A'),
      'canonicalGuard',count(*) FILTER (WHERE uses_canonical_guard),'expected',5)
  FROM immutable_triggers
  UNION ALL
  SELECT 'customer_return_receipt_immutable_guard_contract',
    CASE WHEN count(routine.oid)=2 AND bool_and(routine.prosecdef
      AND position('BACKOFFICE_SALES_RETURN_RECEIPT_HISTORY_IMMUTABLE' in routine.prosrc)>0)
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(routine.oid)=2 AND bool_and(routine.prosecdef
      AND position('BACKOFFICE_SALES_RETURN_RECEIPT_HISTORY_IMMUTABLE' in routine.prosrc)>0)
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('routineRows',count(routine.oid),'expected',2,
      'securityDefiner',COALESCE(bool_and(routine.prosecdef),false))
  FROM (VALUES
    ('private.trg_guard_backoffice_sales_return_receipt_history()'),
    ('private.trg_reject_backoffice_sales_return_receipt_history_mutation()')
  ) expected(signature)
  LEFT JOIN pg_proc routine ON routine.oid=to_regprocedure(expected.signature)
  UNION ALL
  SELECT 'customer_return_receipt_permission_contract',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED'
      AND supported_capabilities @> ARRAY['VIEW','POST']
      AND operator_roles @> ARRAY['WAREHOUSE_ADMIN']
      AND approver_roles @> ARRAY['WAREHOUSE_ADMIN']) THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED'
      AND supported_capabilities @> ARRAY['VIEW','POST']
      AND operator_roles @> ARRAY['WAREHOUSE_ADMIN']
      AND approver_roles @> ARRAY['WAREHOUSE_ADMIN']) THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('permissionRows',count(*))
  FROM public.access_permission_catalog WHERE permission_key='inventory.customer_return_receipts'
  UNION ALL
  SELECT 'customer_return_receipt_master_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_returns document
  WHERE document.total_received_base_qty<>COALESCE((SELECT sum(receipt.total_received_base_qty)
      FROM public.backoffice_sales_return_receipts receipt
      WHERE receipt.company_id=document.company_id AND receipt.return_id=document.id),0)
    OR document.total_restocked_base_qty<>COALESCE((SELECT sum(receipt.total_restocked_base_qty)
      FROM public.backoffice_sales_return_receipts receipt
      WHERE receipt.company_id=document.company_id AND receipt.return_id=document.id),0)
    OR document.total_destroyed_base_qty<>COALESCE((SELECT sum(receipt.total_destroyed_base_qty)
      FROM public.backoffice_sales_return_receipts receipt
      WHERE receipt.company_id=document.company_id AND receipt.return_id=document.id),0)
  UNION ALL
  SELECT 'customer_return_receipt_line_fifo_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_return_receipt_lines line
  WHERE line.received_base_qty<>COALESCE((SELECT sum(restoration.quantity_base)
      FROM public.backoffice_sales_return_receipt_fifo_restorations restoration
      WHERE restoration.company_id=line.company_id AND restoration.receipt_line_id=line.id),0)
    OR line.fifo_cost_total<>COALESCE((SELECT sum(restoration.total_cost)
      FROM public.backoffice_sales_return_receipt_fifo_restorations restoration
      WHERE restoration.company_id=line.company_id AND restoration.receipt_line_id=line.id),0)
  UNION ALL
  SELECT 'customer_return_receipt_restock_movement_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_return_receipt_lines line
  LEFT JOIN public.stock_movements movement ON movement.company_id=line.company_id
    AND movement.id=line.stock_movement_id
  WHERE (line.disposition='RESTOCK' AND (movement.id IS NULL
      OR movement.movement_type<>'SALES_RETURN' OR movement.qty_change<>line.received_base_qty
      OR movement.reference_table<>'backoffice_sales_return_receipts'))
    OR (line.disposition='DESTROY' AND line.stock_movement_id IS NOT NULL)
  UNION ALL
  SELECT 'customer_return_receipt_source_allocation_cap',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('overAllocatedSources',count(*))
  FROM public.backoffice_sales_receipt_fifo_allocations source
  WHERE COALESCE((SELECT sum(restoration.quantity_base)
    FROM public.backoffice_sales_return_receipt_fifo_restorations restoration
    WHERE restoration.company_id=source.company_id
      AND restoration.source_customer_receipt_fifo_allocation_id=source.id),0)>source.quantity_base
  UNION ALL
  SELECT 'customer_return_receipt_finance_boundary','PASS',0::bigint,
    jsonb_build_object('rule','Step 2 tables contain no Financial Event, Journal, Invoice, Credit Note or Refund foreign key')
  UNION ALL
  SELECT 'customer_return_receipt_runtime_inventory','INFO',0::bigint,
    jsonb_build_object('receipts',(SELECT count(*) FROM public.backoffice_sales_return_receipts),
      'restockLines',(SELECT count(*) FROM public.backoffice_sales_return_receipt_lines WHERE disposition='RESTOCK'),
      'destroyLines',(SELECT count(*) FROM public.backoffice_sales_return_receipt_lines WHERE disposition='DESTROY'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
-- END_FULL_POSTFLIGHT_20260917122000
