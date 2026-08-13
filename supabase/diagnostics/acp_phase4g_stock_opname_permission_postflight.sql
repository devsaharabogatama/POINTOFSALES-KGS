-- ACP-4G postflight: enforced Stock Opname channel and capability boundary.
-- SAFETY: SELECT-only; aggregate metadata only.

WITH required_relations(relation_name) AS (
  VALUES ('stock_opnames'),('stock_opname_details'),
    ('stock_opname_count_attempts'),('stock_opname_audit')
), public_routines(routine_name) AS (
  VALUES ('save_stock_opname_session'),('start_stock_opname'),
    ('record_stock_opname_count'),('complete_stock_opname'),
    ('request_stock_opname_recount'),('post_stock_opname'),
    ('cancel_stock_opname'),('get_stock_opname_blind_session'),
    ('get_inventory_stock_opnames')
), routine_state AS (
  SELECT procedure.oid,procedure.proname,
    pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.proname IN(SELECT routine_name FROM public_routines)
), private_core_names(routine_name) AS (
  VALUES ('save_stock_opname_session'),('start_stock_opname'),
    ('record_stock_opname_count'),('complete_stock_opname'),
    ('request_stock_opname_recount'),('post_stock_opname'),
    ('cancel_stock_opname'),('get_stock_opname_blind_session')
), movement_totals AS (
  SELECT company_id,product_id,warehouse_id,COALESCE(sum(qty_change),0) qty
  FROM public.stock_movements GROUP BY company_id,product_id,warehouse_id
), fifo_totals AS (
  SELECT company_id,product_id,warehouse_id,COALESCE(sum(qty_remaining),0) qty
  FROM public.product_batches GROUP BY company_id,product_id,warehouse_id
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260812190000'

  UNION ALL
  SELECT 'stock_opname_permission_enforced',
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE
      enforcement_status='ENFORCED' AND is_customizable
      AND operator_roles=ARRAY[
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'
      ]::TEXT[] AND supported_capabilities @> ARRAY[
        'VIEW','CREATE_DRAFT','EDIT_DRAFT','REVIEW','POST','CANCEL_FINAL'
      ]::TEXT[])=1 THEN 0 ELSE 1 END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='inventory.stock_opnames'

  UNION ALL
  SELECT 'required_stock_opname_public_routines',
    CASE WHEN count(DISTINCT proname)=9
      AND count(*) FILTER(WHERE has_function_privilege(
        'authenticated',oid,'EXECUTE'))=count(*)
      AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0
      THEN 0 ELSE 1 END,
    jsonb_build_object('routine_names',COALESCE(jsonb_agg(DISTINCT proname
      ORDER BY proname),'[]'::JSONB),'signature_rows',count(*))
  FROM routine_state

  UNION ALL
  SELECT 'stock_opname_public_runtime_guard',
    CASE WHEN count(*)=9
      AND count(*) FILTER(WHERE
        (definition ILIKE '%acp_require_stock_opname_counter%'
          OR definition ILIKE '%acp_require_permission_capability%'))=9
      AND count(*) FILTER(WHERE proname='get_inventory_stock_opnames'
        AND definition ILIKE '%inventory.stock_opnames%'
        AND definition ILIKE '%''VIEW''%')=1
      AND count(*) FILTER(WHERE proname='post_stock_opname'
        AND definition ILIKE '%inventory.stock_opnames%'
        AND definition ILIKE '%''POST''%')=1
      THEN 0 ELSE 1 END,
    jsonb_build_object('routine_rows',count(*),'guarded_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_stock_opname_counter%'
        OR definition ILIKE '%acp_require_permission_capability%'))
  FROM routine_state

  UNION ALL
  SELECT 'stock_opname_private_core_boundary',
    CASE WHEN count(DISTINCT procedure.proname)=8
      AND count(*) FILTER(WHERE has_function_privilege(
        'authenticated',procedure.oid,'EXECUTE'))=0
      AND count(*) FILTER(WHERE has_function_privilege(
        'anon',procedure.oid,'EXECUTE'))=0 THEN 0 ELSE 1 END,
    jsonb_build_object('core_names',COALESCE(jsonb_agg(DISTINCT
      procedure.proname ORDER BY procedure.proname),'[]'::JSONB),
      'authenticated_executable',count(*) FILTER(WHERE has_function_privilege(
        'authenticated',procedure.oid,'EXECUTE')))
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private'
    AND procedure.proname IN(SELECT routine_name FROM private_core_names)

  UNION ALL
  SELECT 'stock_opname_direct_read_write_boundary',
    count(*) FILTER(WHERE has_table_privilege('authenticated',
      format('public.%I',relation_name),'SELECT,INSERT,UPDATE,DELETE')),
    jsonb_build_object('direct_relations',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE has_table_privilege('authenticated',
        format('public.%I',relation_name),'SELECT,INSERT,UPDATE,DELETE')),
      '[]'::JSONB))
  FROM required_relations

  UNION ALL
  SELECT 'legacy_stock_opname_helper_browser_execution',
    count(*) FILTER(WHERE has_function_privilege(
      'authenticated',procedure.oid,'EXECUTE')),
    jsonb_build_object('executable_rows',count(*) FILTER(WHERE
      has_function_privilege('authenticated',procedure.oid,'EXECUTE')))
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND procedure.proname IN(
    'private_stock_opname_counter_allowed',
    'get_stock_opname_adjustment_references')

  UNION ALL
  SELECT 'stock_opname_override_tenant_integrity',count(*),
    jsonb_build_object('row_count',count(*))
  FROM public.user_company_permission_overrides override_row
  LEFT JOIN public.company_memberships membership
    ON membership.company_id=override_row.company_id
   AND membership.user_id=override_row.user_id AND membership.status='ACTIVE'
  WHERE override_row.permission_key='inventory.stock_opnames'
    AND membership.id IS NULL

  UNION ALL
  SELECT 'invalid_stock_opname_lifecycle',count(*),
    jsonb_build_object('row_count',count(*))
  FROM public.stock_opnames opname
  WHERE (status='DRAFT'::public.opname_status AND (
      count_started_at IS NOT NULL OR completed_at IS NOT NULL
      OR posted_at IS NOT NULL OR canceled_at IS NOT NULL))
    OR (status='COUNTING'::public.opname_status AND (
      count_started_at IS NULL OR completed_at IS NOT NULL
      OR posted_at IS NOT NULL OR canceled_at IS NOT NULL))
    OR (status='COMPLETED'::public.opname_status AND (
      count_started_at IS NULL OR completed_at IS NULL
      OR posted_at IS NOT NULL OR canceled_at IS NOT NULL))
    OR (status='POSTED'::public.opname_status AND (
      posted_at IS NULL OR posting_idempotency_key IS NULL
      OR canceled_at IS NOT NULL))
    OR (status='CANCELED'::public.opname_status AND canceled_at IS NULL)

  UNION ALL
  SELECT 'invalid_stock_opname_line_shape',count(*),
    jsonb_build_object('row_count',count(*))
  FROM public.stock_opname_details line
  WHERE system_qty_at_start<0 OR physical_qty<0
    OR (line_status IN('COUNTED','RECOUNT_REQUIRED','POSTED') AND (
      counted_at IS NULL OR counter_id IS NULL
      OR expected_qty_at_count IS NULL OR variance_at_count IS NULL
      OR variance_at_count IS DISTINCT FROM
        physical_qty-expected_qty_at_count))
    OR (line_status='SUPERSEDED' AND superseded_by_line_id IS NULL)

  UNION ALL
  SELECT 'posted_stock_opname_final_evidence',count(*),
    jsonb_build_object('row_count',count(*))
  FROM public.stock_opnames opname
  LEFT JOIN public.stock_adjustment_documents adjustment
    ON adjustment.company_id=opname.company_id
   AND adjustment.id=opname.adjustment_document_id
  WHERE opname.status='POSTED'::public.opname_status AND (
    EXISTS(SELECT 1 FROM public.stock_opname_details line
      WHERE line.company_id=opname.company_id AND line.opname_id=opname.id
        AND line.line_status NOT IN('POSTED','SUPERSEDED'))
    OR (opname.adjustment_document_id IS NOT NULL AND (
      adjustment.id IS NULL OR adjustment.status<>'POSTED')))

  UNION ALL
  SELECT 'stock_balance_movement_reconciliation',count(*),
    jsonb_build_object('pair_count',count(*))
  FROM (
    SELECT COALESCE(stock.company_id,movement.company_id)
    FROM public.product_stocks stock FULL JOIN movement_totals movement
      ON movement.company_id=stock.company_id
     AND movement.product_id=stock.product_id
     AND movement.warehouse_id=stock.warehouse_id
    WHERE COALESCE(stock.stock_qty,0)<>COALESCE(movement.qty,0)
  ) invalid_pair

  UNION ALL
  SELECT 'stock_balance_fifo_reconciliation',count(*),
    jsonb_build_object('pair_count',count(*))
  FROM public.product_stocks stock LEFT JOIN fifo_totals fifo
    ON fifo.company_id=stock.company_id AND fifo.product_id=stock.product_id
   AND fifo.warehouse_id=stock.warehouse_id
  WHERE stock.stock_qty>0 AND stock.stock_qty<>COALESCE(fifo.qty,0)

  UNION ALL
  SELECT 'stock_opname_runtime_inventory',0,jsonb_build_object(
    'sessions',count(*),'drafts',count(*) FILTER(WHERE status='DRAFT'),
    'counting',count(*) FILTER(WHERE status='COUNTING'),
    'completed',count(*) FILTER(WHERE status='COMPLETED'),
    'posted',count(*) FILTER(WHERE status='POSTED'),
    'canceled',count(*) FILTER(WHERE status='CANCELED'),
    'details',(SELECT count(*) FROM public.stock_opname_details),
    'attempts',(SELECT count(*) FROM public.stock_opname_count_attempts),
    'overrides',(SELECT count(*) FROM public.user_company_permission_overrides
      WHERE permission_key='inventory.stock_opnames'))
  FROM public.stock_opnames
)
SELECT check_name,CASE WHEN violation_rows=0 THEN 'PASS' ELSE 'FAIL' END status,
  violation_rows,details
FROM checks ORDER BY CASE WHEN violation_rows>0 THEN 1 ELSE 2 END,check_name;
