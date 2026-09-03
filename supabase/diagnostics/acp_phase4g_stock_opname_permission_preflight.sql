-- ACP-4G preflight: Stock Opname complete permission-cutover readiness.
-- SAFETY: one SELECT statement; aggregate metadata only; no business identity.

WITH required_versions(version) AS (
  VALUES ('20260728230000'),('20260812120000'),('20260812180000')
), required_relations(relation_name) AS (
  VALUES ('stock_opnames'),('stock_opname_details'),
    ('stock_opname_count_attempts'),('stock_opname_audit')
), required_routines(routine_name) AS (
  VALUES ('save_stock_opname_session'),('start_stock_opname'),
    ('record_stock_opname_count'),('complete_stock_opname'),
    ('request_stock_opname_recount'),('post_stock_opname'),
    ('cancel_stock_opname'),('get_stock_opname_blind_session')
), routine_state AS (
  SELECT procedure.oid,procedure.proname,
    pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.proname IN(SELECT routine_name FROM required_routines)
), private_post_state AS (
  SELECT procedure.oid,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private'
    AND procedure.proname='post_stock_opname'
), movement_totals AS (
  SELECT company_id,product_id,warehouse_id,COALESCE(sum(qty_change),0) qty
  FROM public.stock_movements GROUP BY company_id,product_id,warehouse_id
), stock_reconciliation AS (
  SELECT COALESCE(stock.company_id,movement.company_id) company_id,
    COALESCE(stock.product_id,movement.product_id) product_id,
    COALESCE(stock.warehouse_id,movement.warehouse_id) warehouse_id,
    COALESCE(stock.stock_qty,0) stock_qty,COALESCE(movement.qty,0) movement_qty
  FROM public.product_stocks stock FULL JOIN movement_totals movement
    ON movement.company_id=stock.company_id
   AND movement.product_id=stock.product_id
   AND movement.warehouse_id=stock.warehouse_id
), fifo_totals AS (
  SELECT company_id,product_id,warehouse_id,COALESCE(sum(qty_remaining),0) qty
  FROM public.product_batches GROUP BY company_id,product_id,warehouse_id
), checks AS (
  SELECT 'acp_phase4g_dependencies'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(
      required.version ORDER BY required.version) FILTER(
        WHERE migration.version IS NULL),'[]'::JSONB)) details
  FROM required_versions required LEFT JOIN private.kgs_schema_migrations migration
    ON migration.version=required.version

  UNION ALL
  SELECT 'stock_opname_permission_catalog_state',
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE enforcement_status='SHADOW'
      AND is_customizable AND supported_capabilities @> ARRAY[
        'VIEW','CREATE_DRAFT','EDIT_DRAFT','REVIEW','POST','CANCEL_FINAL'
      ]::TEXT[])=1 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB),'capabilities',COALESCE(
      (SELECT to_jsonb(supported_capabilities)
       FROM public.access_permission_catalog
       WHERE permission_key='inventory.stock_opnames'),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='inventory.stock_opnames'

  UNION ALL
  SELECT 'stock_opname_override_tenant_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.user_company_permission_overrides override_row
  LEFT JOIN public.company_memberships membership
    ON membership.company_id=override_row.company_id
   AND membership.user_id=override_row.user_id AND membership.status='ACTIVE'
  WHERE override_row.permission_key='inventory.stock_opnames'
    AND membership.id IS NULL

  UNION ALL
  SELECT 'canonical_stock_opname_schema_state',
    CASE WHEN count(*) FILTER(WHERE to_regclass(
      format('public.%I',relation_name)) IS NULL)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(
      relation_name ORDER BY relation_name) FILTER(WHERE to_regclass(
        format('public.%I',relation_name)) IS NULL),'[]'::JSONB))
  FROM required_relations

  UNION ALL
  SELECT 'stock_opname_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE has_table_privilege('authenticated',
      format('public.%I',relation_name),'INSERT,UPDATE,DELETE'))=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('direct_write_relations',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE has_table_privilege('authenticated',
        format('public.%I',relation_name),'INSERT,UPDATE,DELETE')),'[]'::JSONB))
  FROM required_relations

  UNION ALL
  SELECT 'stock_opname_direct_read_cutover_scope','REVIEW',
    jsonb_build_object('authenticated_read_relations',COALESCE(jsonb_agg(
      relation_name ORDER BY relation_name) FILTER(WHERE has_table_privilege(
        'authenticated',format('public.%I',relation_name),'SELECT')),'[]'::JSONB),
      'required_design',ARRAY[
        'replace Backoffice table reads with one Stock Opname VIEW-guarded RPC',
        'include attempts, actor labels, Adjustment proof, and narrow Warehouse references',
        'revoke direct SELECT only after every active browser consumer is migrated'
      ])
  FROM required_relations

  UNION ALL
  SELECT 'canonical_stock_opname_read_rpc_state','SETUP',
    jsonb_build_object('rpc_exists',to_regprocedure(
      'public.get_inventory_stock_opnames()') IS NOT NULL)

  UNION ALL
  SELECT 'stock_opname_mutation_routine_state',
    CASE WHEN count(DISTINCT proname)=8
      AND count(*) FILTER(WHERE has_function_privilege(
        'authenticated',oid,'EXECUTE'))=count(*)
      AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routine_names',COALESCE(jsonb_agg(DISTINCT proname
      ORDER BY proname),'[]'::JSONB),'signature_rows',count(*),
      'authenticated_rows',count(*) FILTER(WHERE has_function_privilege(
        'authenticated',oid,'EXECUTE')),
      'anon_rows',count(*) FILTER(WHERE has_function_privilege(
        'anon',oid,'EXECUTE')))
  FROM routine_state

  UNION ALL
  SELECT 'stock_opname_runtime_permission_hook_state','SETUP',
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'
        AND definition ILIKE '%inventory.stock_opnames%'))
  FROM routine_state

  UNION ALL
  SELECT 'stock_opname_channel_authority_split','REVIEW',jsonb_build_object(
    'counter_helper_exists',to_regprocedure(
      'public.private_stock_opname_counter_allowed(uuid,uuid)') IS NOT NULL,
    'catalog_view_roles',(SELECT to_jsonb(view_roles)
      FROM public.access_permission_catalog
      WHERE permission_key='inventory.stock_opnames'),
    'catalog_operator_roles',(SELECT to_jsonb(operator_roles)
      FROM public.access_permission_catalog
      WHERE permission_key='inventory.stock_opnames'),
    'required_design',ARRAY[
      'Backoffice report requires effective VIEW and never exposes blind-count authority',
      'Cashier blind create/count remains limited by active Store role and Warehouse scope',
      'custom restriction may reduce an eligible counter but must not widen Store scope',
      'REVIEW/POST remain Company Owner/Admin/Store Manager authority'
    ])

  UNION ALL
  SELECT 'stock_opname_reference_consumer_scope','REVIEW',jsonb_build_object(
    'required_design',ARRAY[
      'Backoffice VIEW returns only Opname-scoped Warehouse and actor labels',
      'Finance/Accounting viewers must not require inventory.master_data VIEW',
      'blind payload must never include system, expected, physical, or variance quantities',
      'client-supplied purpose must never bypass effective permission or Store scope'
    ])

  UNION ALL
  SELECT 'stock_opname_trusted_adjustment_core',
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE
      definition ILIKE '%private.save_stock_adjustment_document%'
      AND definition ILIKE '%private.post_stock_adjustment%')=1
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('private_post_rows',count(*),
      'trusted_adjustment_calls',count(*) FILTER(WHERE
        definition ILIKE '%private.save_stock_adjustment_document%'
        AND definition ILIKE '%private.post_stock_adjustment%'))
  FROM private_post_state

  UNION ALL
  SELECT 'stock_opname_tenant_reference_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('orphan_or_cross_tenant_rows',count(*))
  FROM (
    SELECT opname.id FROM public.stock_opnames opname
    LEFT JOIN public.warehouses warehouse
      ON warehouse.company_id=opname.company_id
     AND warehouse.id=opname.warehouse_id
    WHERE warehouse.id IS NULL
    UNION ALL
    SELECT line.id FROM public.stock_opname_details line
    LEFT JOIN public.stock_opnames opname
      ON opname.company_id=line.company_id AND opname.id=line.opname_id
    LEFT JOIN public.products product
      ON product.company_id=line.company_id AND product.id=line.product_id
    WHERE opname.id IS NULL OR product.id IS NULL
  ) invalid_row

  UNION ALL
  SELECT 'invalid_stock_opname_lifecycle',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
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
      posted_at IS NULL OR posted_by IS NULL
      OR posting_idempotency_key IS NULL OR canceled_at IS NOT NULL))
    OR (status='CANCELED'::public.opname_status AND (
      canceled_at IS NULL OR canceled_by IS NULL OR posted_at IS NOT NULL))

  UNION ALL
  SELECT 'invalid_stock_opname_line_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.stock_opname_details line
  WHERE physical_qty<0
    OR (line_status IN('COUNTED','RECOUNT_REQUIRED','POSTED') AND (
      counted_at IS NULL OR counter_id IS NULL
      OR expected_qty_at_count IS NULL OR variance_at_count IS NULL
      OR variance_at_count IS DISTINCT FROM
        physical_qty-expected_qty_at_count))
    OR (line_status='SUPERSEDED' AND superseded_by_line_id IS NULL)

  UNION ALL
  SELECT 'invalid_stock_opname_attempt_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.stock_opname_count_attempts attempt
  LEFT JOIN public.stock_opnames opname
    ON opname.company_id=attempt.company_id AND opname.id=attempt.opname_id
  LEFT JOIN public.stock_opname_details line
    ON line.company_id=attempt.company_id
   AND line.id=attempt.opname_detail_id
   AND line.opname_id=attempt.opname_id
  WHERE opname.id IS NULL OR line.id IS NULL OR attempt.attempt_no<=0
    OR attempt.physical_qty<0 OR attempt.counted_at<attempt.count_started_at

  UNION ALL
  SELECT 'duplicate_active_product_warehouse_count',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicate_groups',count(*))
  FROM (
    SELECT line.company_id,opname.warehouse_id,line.product_id
    FROM public.stock_opname_details line JOIN public.stock_opnames opname
      ON opname.company_id=line.company_id AND opname.id=line.opname_id
    WHERE line.line_status IN('COUNTED','RECOUNT_REQUIRED')
      AND opname.status NOT IN(
        'POSTED'::public.opname_status,'CANCELED'::public.opname_status)
    GROUP BY line.company_id,opname.warehouse_id,line.product_id
    HAVING count(*)>1
  ) duplicate_group

  UNION ALL
  SELECT 'posted_stock_opname_final_evidence',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.stock_opnames opname
  LEFT JOIN public.stock_adjustment_documents adjustment
    ON adjustment.company_id=opname.company_id
   AND adjustment.id=opname.adjustment_document_id
  WHERE opname.status='POSTED'::public.opname_status AND (
    EXISTS(SELECT 1 FROM public.stock_opname_details line
      WHERE line.company_id=opname.company_id AND line.opname_id=opname.id
        AND line.line_status NOT IN('POSTED','SKIPPED','SUPERSEDED'))
    OR (opname.adjustment_document_id IS NOT NULL AND (
      adjustment.id IS NULL OR adjustment.status<>'POSTED')))

  UNION ALL
  SELECT 'duplicate_stock_opname_posting_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicate_groups',count(*))
  FROM (SELECT company_id,posting_idempotency_key
    FROM public.stock_opnames WHERE posting_idempotency_key IS NOT NULL
    GROUP BY company_id,posting_idempotency_key HAVING count(*)>1) duplicate_group

  UNION ALL
  SELECT 'stock_balance_movement_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('pair_count',count(*))
  FROM stock_reconciliation WHERE stock_qty<>movement_qty

  UNION ALL
  SELECT 'stock_balance_fifo_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('pair_count',count(*))
  FROM public.product_stocks stock LEFT JOIN fifo_totals fifo
    ON fifo.company_id=stock.company_id AND fifo.product_id=stock.product_id
   AND fifo.warehouse_id=stock.warehouse_id
  WHERE stock.stock_qty>0 AND stock.stock_qty<>COALESCE(fifo.qty,0)

  UNION ALL
  SELECT 'stock_opname_runtime_inventory','INFO',jsonb_build_object(
    'sessions',count(*),'drafts',count(*) FILTER(WHERE status='DRAFT'),
    'counting',count(*) FILTER(WHERE status='COUNTING'),
    'completed',count(*) FILTER(WHERE status='COMPLETED'),
    'posted',count(*) FILTER(WHERE status='POSTED'),
    'canceled',count(*) FILTER(WHERE status='CANCELED'),
    'companies',count(DISTINCT company_id),
    'detail_rows',(SELECT count(*) FROM public.stock_opname_details),
    'attempt_rows',(SELECT count(*) FROM public.stock_opname_count_attempts),
    'override_rows',(SELECT count(*)
      FROM public.user_company_permission_overrides
      WHERE permission_key='inventory.stock_opnames'))
  FROM public.stock_opnames
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2
  WHEN 'SETUP' THEN 3 WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
