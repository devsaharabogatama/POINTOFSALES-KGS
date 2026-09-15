-- Cutover Step 4A/6: SELECT-only preflight. Run as one complete statement.
WITH required_versions(version) AS (VALUES
  ('20260805190000'::text),('20260805220000'),('20260828100000'),
  ('20260828140000'),('20260903110000'),('20260909147000'),('20260910152000')
), checks AS (
  SELECT 'dependency_ledger'::text check_name,
    CASE WHEN count(ledger.version)=7 THEN 'PASS' ELSE 'BLOCKER' END status,
    (7-count(ledger.version))::bigint violation_rows,
    jsonb_build_object('expected',7,'present',count(ledger.version)) details
  FROM required_versions expected LEFT JOIN private.kgs_schema_migrations ledger USING(version)
  UNION ALL
  SELECT 'warehouse_authority_column_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('existingColumns',COALESCE(jsonb_agg(table_name||'.'||column_name),'[]'::jsonb))
  FROM information_schema.columns WHERE table_schema='public' AND
    ((table_name='sales_stock_reservation_lines' AND column_name IN('negative_authority_source','negative_warehouse_version'))
      OR (table_name='pos_negative_stock_authorizations' AND column_name IN('authority_source','warehouse_version')))
  UNION ALL
  SELECT 'canonical_runtime_contract',CASE WHEN count(routine_oid)=5 THEN 'PASS' ELSE 'BLOCKER' END,
    (5-count(routine_oid))::bigint,jsonb_build_object('expected',5,'present',count(routine_oid))
  FROM (VALUES
    (to_regprocedure('private.authorize_pos_negative_stock(uuid,uuid,uuid,uuid,jsonb,text)')),
    (to_regprocedure('private.confirm_pos_sales_order_core(uuid,bigint,uuid,text)')),
    (to_regprocedure('private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)')),
    (to_regprocedure('public.confirm_pos_sales_order(uuid,bigint,uuid,text)')),
    (to_regprocedure('private.dispatch_sales_delivery_stock_core_odr3c(uuid,bigint,uuid,jsonb,text)'))
  ) required(routine_oid)
  UNION ALL
  SELECT 'canonical_retail_call_chain_contract',CASE
      WHEN COALESCE(pg_get_functiondef(to_regprocedure(
          'private.confirm_pos_sales_order_core(uuid,bigint,uuid,text)')),'')
          ~'pos_negative_stock_permissions'
        AND COALESCE(pg_get_functiondef(to_regprocedure(
          'private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)')),'')
          ~'private.confirm_pos_sales_order_core'
        AND COALESCE(pg_get_functiondef(to_regprocedure(
          'private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)')),'')
          ~'ensure_confirmed_order_invoice_identity'
        AND COALESCE(pg_get_functiondef(to_regprocedure(
          'private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)')),'')
          ~'ensure_confirmed_order_documents'
        AND COALESCE(pg_get_functiondef(to_regprocedure(
          'private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)')),'')
          ~'refresh_sales_order_procurement_demand'
        AND COALESCE(pg_get_functiondef(to_regprocedure(
          'private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)')),'')
          ~'capture_sales_order_payment_requests'
        AND COALESCE(pg_get_functiondef(to_regprocedure(
          'public.confirm_pos_sales_order(uuid,bigint,uuid,text)')),'')
          ~'private.confirm_pos_sales_order_before_revision_core'
        AND COALESCE(pg_get_functiondef(to_regprocedure(
          'public.confirm_pos_sales_order(uuid,bigint,uuid,text)')),'')
          ~'sales_order_revisions'
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN COALESCE(pg_get_functiondef(to_regprocedure(
          'private.confirm_pos_sales_order_core(uuid,bigint,uuid,text)')),'')
          ~'pos_negative_stock_permissions'
        AND COALESCE(pg_get_functiondef(to_regprocedure(
          'private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)')),'')
          ~'private.confirm_pos_sales_order_core'
        AND COALESCE(pg_get_functiondef(to_regprocedure(
          'private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)')),'')
          ~'ensure_confirmed_order_invoice_identity'
        AND COALESCE(pg_get_functiondef(to_regprocedure(
          'private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)')),'')
          ~'ensure_confirmed_order_documents'
        AND COALESCE(pg_get_functiondef(to_regprocedure(
          'private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)')),'')
          ~'refresh_sales_order_procurement_demand'
        AND COALESCE(pg_get_functiondef(to_regprocedure(
          'private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)')),'')
          ~'capture_sales_order_payment_requests'
        AND COALESCE(pg_get_functiondef(to_regprocedure(
          'public.confirm_pos_sales_order(uuid,bigint,uuid,text)')),'')
          ~'private.confirm_pos_sales_order_before_revision_core'
        AND COALESCE(pg_get_functiondef(to_regprocedure(
          'public.confirm_pos_sales_order(uuid,bigint,uuid,text)')),'')
          ~'sales_order_revisions' THEN 0 ELSE 1 END,
    jsonb_build_object('chain',jsonb_build_array(
      'public.confirm_pos_sales_order','private.confirm_pos_sales_order_before_revision_core',
      'private.confirm_pos_sales_order_core'))
  UNION ALL
  SELECT 'legacy_reservation_evidence',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.sales_stock_reservation_lines WHERE shortage_base_qty>0
    AND (negative_policy_version IS NULL OR negative_permission_version IS NULL)
  UNION ALL
  SELECT 'legacy_authorization_evidence',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.pos_negative_stock_authorizations WHERE permission_id IS NULL
    OR NULLIF(btrim(reason),'') IS NULL OR policy_version<=0 OR permission_version<=0
  UNION ALL
  SELECT 'open_cutover_plan_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('openPlans',count(*),'required','Cancel and recreate after authority upgrade')
  FROM public.sales_process_cutover_plans WHERE status IN('DRAFT','PREVIEWED','APPLYING')
  UNION ALL
  SELECT 'active_finance_queue_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('activeRuns',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'negative_runtime_inventory','INFO',0::bigint,jsonb_build_object(
    'legacyReservationShortageRows',(SELECT count(*) FROM public.sales_stock_reservation_lines WHERE shortage_base_qty>0),
    'legacyAuthorizations',(SELECT count(*) FROM public.pos_negative_stock_authorizations),
    'warehouseOptIns',(SELECT count(*) FROM public.warehouses WHERE is_active AND is_sale_source AND allow_negative_stock))
  UNION ALL
  SELECT 'preflight_environment_identity','INFO',0::bigint,jsonb_build_object(
    'database',current_database(),'databaseUser',current_user,'serverAddress',inet_server_addr()::text,
    'serverPort',inet_server_port(),'requiredProjectRef','fkywtxucmyjvpwdiqpix')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
