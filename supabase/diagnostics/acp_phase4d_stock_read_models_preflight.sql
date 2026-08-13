-- ACP-4D preflight: Stock Real and Stock Movement read-model cutover.
-- SAFETY: one SELECT statement; aggregate metadata only; no business identity.

WITH required_versions(version) AS (
  VALUES ('20260812140000'),('20260812150000')
), expected_permissions(permission_key) AS (
  VALUES ('inventory.stock_real'),('inventory.stock_movements')
), movement_totals AS (
  SELECT company_id,product_id,warehouse_id,
    COALESCE(sum(qty_change) FILTER(WHERE movement_status='POSTED'),0) movement_qty
  FROM public.stock_movements GROUP BY company_id,product_id,warehouse_id
), stock_reconciliation AS (
  SELECT COALESCE(stock.company_id,movement.company_id) company_id,
    COALESCE(stock.product_id,movement.product_id) product_id,
    COALESCE(stock.warehouse_id,movement.warehouse_id) warehouse_id,
    COALESCE(stock.stock_qty,0) stock_qty,
    COALESCE(movement.movement_qty,0) movement_qty
  FROM public.product_stocks stock FULL JOIN movement_totals movement
    ON movement.company_id=stock.company_id
   AND movement.product_id=stock.product_id
   AND movement.warehouse_id=stock.warehouse_id
), fifo_totals AS (
  SELECT company_id,product_id,warehouse_id,COALESCE(sum(qty_remaining),0) fifo_qty
  FROM public.product_batches GROUP BY company_id,product_id,warehouse_id
), fifo_reconciliation AS (
  SELECT COALESCE(stock.company_id,fifo.company_id) company_id,
    COALESCE(stock.product_id,fifo.product_id) product_id,
    COALESCE(stock.warehouse_id,fifo.warehouse_id) warehouse_id,
    COALESCE(stock.stock_qty,0) stock_qty,COALESCE(fifo.fifo_qty,0) fifo_qty
  FROM public.product_stocks stock FULL JOIN fifo_totals fifo
    ON fifo.company_id=stock.company_id
   AND fifo.product_id=stock.product_id
   AND fifo.warehouse_id=stock.warehouse_id
), latest_movement AS (
  SELECT DISTINCT ON(company_id,product_id,warehouse_id)
    company_id,product_id,warehouse_id,balance_after_base_qty
  FROM public.stock_movements WHERE movement_status='POSTED'
  ORDER BY company_id,product_id,warehouse_id,
    posted_at DESC NULLS LAST,created_at DESC,id DESC
), select_policy_state AS (
  SELECT tablename,count(*) FILTER(WHERE cmd IN('SELECT','ALL')) policy_rows
  FROM pg_policies
  WHERE schemaname='public' AND tablename IN(
    'product_stocks','product_batches','stock_movements'
  ) GROUP BY tablename
), checks AS (
  SELECT 'acp_phase4d_dependencies'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(required.version ORDER BY required.version)
        FILTER(WHERE migration.version IS NULL),'[]'::JSONB)) details
  FROM required_versions required LEFT JOIN private.kgs_schema_migrations migration
    ON migration.version=required.version

  UNION ALL
  SELECT 'stock_read_permission_catalog_state',
    CASE WHEN count(*)=2
      AND count(*) FILTER(WHERE catalog.permission_key IS NULL)=0
      AND count(*) FILTER(WHERE catalog.enforcement_status<>'SHADOW')=0
      AND count(*) FILTER(WHERE NOT catalog.is_customizable)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),
      'missing',count(*) FILTER(WHERE catalog.permission_key IS NULL),
      'non_shadow',count(*) FILTER(WHERE catalog.permission_key IS NOT NULL
        AND catalog.enforcement_status<>'SHADOW'),
      'non_customizable',count(*) FILTER(WHERE catalog.permission_key IS NOT NULL
        AND NOT catalog.is_customizable))
  FROM expected_permissions expected LEFT JOIN public.access_permission_catalog catalog
    ON catalog.permission_key=expected.permission_key

  UNION ALL
  SELECT 'stock_read_override_tenant_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.user_company_permission_overrides override_row
  JOIN expected_permissions expected
    ON expected.permission_key=override_row.permission_key
  LEFT JOIN public.company_memberships membership
    ON membership.company_id=override_row.company_id
   AND membership.user_id=override_row.user_id AND membership.status='ACTIVE'
  LEFT JOIN public.profiles profile ON profile.id=override_row.user_id
  WHERE membership.id IS NULL AND (
    profile.role IS NULL OR profile.role<>'super_admin'::public.user_role
  )

  UNION ALL
  SELECT 'stock_read_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE has_table_privilege(
      'authenticated',format('public.%I',relation_name),'INSERT,UPDATE,DELETE'
    ))=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('direct_write_relations',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE has_table_privilege('authenticated',
        format('public.%I',relation_name),'INSERT,UPDATE,DELETE')),'[]'::JSONB))
  FROM (VALUES('product_stocks'),('product_batches'),('stock_movements'))
    relation(relation_name)

  UNION ALL
  SELECT 'stock_read_rls_policy_state',
    CASE WHEN count(*)=3 AND count(*) FILTER(WHERE policy_rows=0)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('relation_rows',count(*),
      'relations_without_select_policy',COALESCE(jsonb_agg(tablename)
        FILTER(WHERE policy_rows=0),'[]'::JSONB))
  FROM (
    SELECT expected.tablename,COALESCE(policy.policy_rows,0) policy_rows
    FROM (VALUES('product_stocks'),('product_batches'),('stock_movements'))
      expected(tablename)
    LEFT JOIN select_policy_state policy ON policy.tablename=expected.tablename
  ) policy_contract

  UNION ALL
  SELECT 'duplicate_product_warehouse_balance',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicate_groups',count(*))
  FROM (SELECT company_id,product_id,warehouse_id FROM public.product_stocks
    GROUP BY company_id,product_id,warehouse_id HAVING count(*)>1) duplicate_group

  UNION ALL
  SELECT 'stock_balance_tenant_reference_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.product_stocks stock
  LEFT JOIN public.products product ON product.company_id=stock.company_id
    AND product.id=stock.product_id
  LEFT JOIN public.warehouses warehouse ON warehouse.company_id=stock.company_id
    AND warehouse.id=stock.warehouse_id
  WHERE product.id IS NULL OR warehouse.id IS NULL

  UNION ALL
  SELECT 'negative_stock_balance',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
    jsonb_build_object('row_count',count(*))
  FROM public.product_stocks WHERE stock_qty<0

  UNION ALL
  SELECT 'stock_balance_movement_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('pair_count',count(*))
  FROM stock_reconciliation WHERE stock_qty<>movement_qty

  UNION ALL
  SELECT 'stock_balance_fifo_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('pair_count',count(*))
  FROM fifo_reconciliation WHERE stock_qty<>fifo_qty

  UNION ALL
  SELECT 'latest_movement_balance_snapshot',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('pair_count',count(*))
  FROM latest_movement movement LEFT JOIN public.product_stocks stock
    ON stock.company_id=movement.company_id
   AND stock.product_id=movement.product_id
   AND stock.warehouse_id=movement.warehouse_id
  WHERE movement.balance_after_base_qty IS NULL
     OR movement.balance_after_base_qty<>COALESCE(stock.stock_qty,0)

  UNION ALL
  SELECT 'stock_real_composite_read_contract','REVIEW',jsonb_build_object(
    'current_payload',ARRAY[
      'all stock balances','all positive FIFO layers with cost',
      'all stock movements for latest-movement derivation','minimum-stock settings'
    ],
    'required_design',ARRAY[
      'guard Stock Real composite read with inventory.stock_real VIEW',
      'derive valuation and latest movement server-side',
      'do not return the full Stock Movement ledger through Stock Real',
      'preserve narrowly scoped on-hand references for authorized workflows'
    ])

  UNION ALL
  SELECT 'stock_on_hand_shared_consumer_scope','REVIEW',jsonb_build_object(
    'consumer_permissions',ARRAY[
      'inventory.stock_transfers','inventory.stock_adjustments',
      'inventory.stock_opnames','inventory.opening_stock',
      'inventory.minimum_stock','platform.module_settings'
    ],
    'rule','a client-supplied purpose must never bypass stock_real; consumer APIs must authorize their own key')

  UNION ALL
  SELECT 'stock_read_export_runtime_state','SETUP',jsonb_build_object(
    'stock_real_catalog_supports_export',TRUE,
    'stock_movement_catalog_supports_export',TRUE,
    'application_catalog_review_required',TRUE,
    'required','separate export-only datasets guarded by each effective EXPORT capability')

  UNION ALL
  SELECT 'stock_read_runtime_inventory','INFO',jsonb_build_object(
    'companies',(SELECT count(DISTINCT company_id) FROM public.product_stocks),
    'balance_rows',(SELECT count(*) FROM public.product_stocks),
    'positive_fifo_layers',(SELECT count(*) FROM public.product_batches WHERE qty_remaining>0),
    'posted_movements',(SELECT count(*) FROM public.stock_movements WHERE movement_status='POSTED'),
    'stock_real_overrides',(SELECT count(*) FROM public.user_company_permission_overrides
      WHERE permission_key='inventory.stock_real'),
    'stock_movement_overrides',(SELECT count(*) FROM public.user_company_permission_overrides
      WHERE permission_key='inventory.stock_movements'))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2
  WHEN 'SETUP' THEN 3 WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
