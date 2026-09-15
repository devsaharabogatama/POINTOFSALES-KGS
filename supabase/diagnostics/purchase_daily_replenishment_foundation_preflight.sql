-- Purchase Daily Replenishment Step 1/6: SELECT-only foundation preflight.
-- Run the complete file on the isolated Development project only.
WITH required_versions(version) AS (VALUES
  ('20260806010000'::text), -- Stock Request / Supplier Order canonical foundation
  ('20260806040000'),       -- Goods Receipt canonical foundation
  ('20260828190000'),       -- managed procurement reconciliation/read model
  ('20260910153000'),       -- unified Warehouse negative-stock authority
  ('20260912140000')        -- latest isolated-development chain boundary
), checks AS (
  SELECT 'pdr_foundation_dependency_ledger'::text check_name,
    CASE WHEN count(ledger.version)=5 THEN 'PASS' ELSE 'BLOCKER' END status,
    (5-count(ledger.version))::bigint violation_rows,
    jsonb_build_object('expected',5,'present',count(ledger.version),
      'missing',COALESCE(jsonb_agg(expected.version) FILTER(WHERE ledger.version IS NULL),'[]'::jsonb)) details
  FROM required_versions expected
  LEFT JOIN private.kgs_schema_migrations ledger USING(version)
  UNION ALL
  SELECT 'pdr_foundation_schema_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('existing',COALESCE(jsonb_agg(name ORDER BY name),'[]'::jsonb))
  FROM (SELECT table_name name FROM information_schema.tables
    WHERE table_schema='public' AND table_name IN(
      'company_purchase_replenishment_settings','company_purchase_replenishment_setting_audit',
      'purchase_daily_batches','purchase_daily_batch_lines')
    UNION ALL SELECT 'product_suppliers.selection_priority'
    WHERE EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public'
      AND table_name='product_suppliers' AND column_name='selection_priority')) collision
  UNION ALL
  SELECT 'pdr_foundation_routine_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('existing',COALESCE(jsonb_agg(signature ORDER BY signature),'[]'::jsonb))
  FROM (SELECT signature FROM (VALUES
    ('public.get_purchase_replenishment_setting()'::text,to_regprocedure('public.get_purchase_replenishment_setting()')),
    ('public.set_purchase_replenishment_mode(text,bigint)',to_regprocedure('public.set_purchase_replenishment_mode(text,bigint)')),
    ('private.trg_guard_purchase_replenishment_history()',to_regprocedure('private.trg_guard_purchase_replenishment_history()')),
    ('private.trg_provision_purchase_replenishment_setting()',to_regprocedure('private.trg_provision_purchase_replenishment_setting()'))
  ) routine(signature,oid) WHERE oid IS NOT NULL) found
  UNION ALL
  SELECT 'pdr_foundation_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'pdr_foundation_nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'pdr_foundation_open_cutover_plan',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('openPlans',count(*))
  FROM public.sales_process_cutover_plans WHERE status IN('DRAFT','PREVIEWED','APPLYING')
  UNION ALL
  SELECT 'pdr_foundation_runtime_inventory','INFO',0::bigint,jsonb_build_object(
    'companies',(SELECT count(*) FROM public.companies WHERE status='ACTIVE'),
    'negativeOnHandRows',(SELECT count(*) FROM public.product_stocks WHERE stock_qty<0),
    'openRequests',(SELECT count(*) FROM public.stock_request_documents WHERE status IN('DRAFT','SUBMITTED','ORDERED','PARTIALLY_RECEIVED')),
    'openSupplierOrders',(SELECT count(*) FROM public.supplier_order_documents WHERE status IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED')))
  UNION ALL
  SELECT 'pdr_foundation_environment','INFO',0::bigint,jsonb_build_object(
    'database',current_database(),'databaseUser',current_user,'serverAddress',inet_server_addr()::text,
    'serverPort',inet_server_port(),'requiredProjectRef','fkywtxucmyjvpwdiqpix')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
