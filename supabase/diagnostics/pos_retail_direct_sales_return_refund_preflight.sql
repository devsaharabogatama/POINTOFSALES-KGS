-- SELECT-only preflight. Expected state before migration: NOT_INSTALLED.
WITH dependencies(version) AS (VALUES
  ('20260829110000'::text),('20260908100000'),('20260909162000')
), installed AS (
  SELECT version FROM private.kgs_schema_migrations
  WHERE version IN(SELECT version FROM dependencies)
), state AS (
  SELECT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261102100000') ledger,
    EXISTS(SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='sales_return_documents'
        AND column_name='direct_pos_request_hash') hash_column,
    to_regprocedure('public.submit_pos_sales_return_with_delivery_fee(uuid,uuid,text,text,jsonb,jsonb,boolean,uuid)') IS NOT NULL submit_rpc
)
SELECT 'pos_retail_direct_return_preflight_dependency_ledger' check_name,
  CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END status,
  3-count(*) violation_rows,
  jsonb_build_object('required',(SELECT jsonb_agg(version ORDER BY version) FROM dependencies),
    'installed',jsonb_agg(version ORDER BY version)) details FROM installed
UNION ALL
SELECT 'pos_retail_direct_return_preflight_installation_state',
  CASE WHEN NOT ledger AND NOT hash_column AND NOT submit_rpc THEN 'PASS' ELSE 'BLOCKER' END,
  (ledger::int+hash_column::int+submit_rpc::int),
  jsonb_build_object('classification',CASE
    WHEN NOT ledger AND NOT hash_column AND NOT submit_rpc THEN 'NOT_INSTALLED'
    WHEN ledger AND hash_column AND submit_rpc THEN 'INSTALLED_CONSISTENT'
    ELSE 'PARTIAL/INCONSISTENT' END,'ledger',ledger,
    'hashColumn',hash_column,'submitRpc',submit_rpc) FROM state
UNION ALL
SELECT 'pos_retail_direct_return_preflight_runtime_anchors',
  CASE WHEN to_regprocedure('private.acp5h_post_sales_return_core(uuid,bigint,uuid)') IS NOT NULL
      AND to_regprocedure('public.save_sales_return_draft_with_delivery_fee(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb,boolean)') IS NOT NULL
      AND to_regclass('public.company_sales_process_settings') IS NOT NULL
    THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN to_regprocedure('private.acp5h_post_sales_return_core(uuid,bigint,uuid)') IS NOT NULL
      AND to_regprocedure('public.save_sales_return_draft_with_delivery_fee(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb,boolean)') IS NOT NULL
      AND to_regclass('public.company_sales_process_settings') IS NOT NULL
    THEN 0 ELSE 1 END,
  jsonb_build_object('postCore',to_regprocedure('private.acp5h_post_sales_return_core(uuid,bigint,uuid)')::text,
    'draftSaver',to_regprocedure('public.save_sales_return_draft_with_delivery_fee(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb,boolean)')::text,
    'processSettings',to_regclass('public.company_sales_process_settings')::text)
UNION ALL
SELECT 'pos_retail_direct_return_preflight_process_inventory','INFO',0,
  jsonb_build_object('companies',COALESCE(jsonb_agg(jsonb_build_object(
    'code',company.company_code,'activeMode',setting.active_mode)
    ORDER BY company.company_code),'[]'::jsonb))
FROM public.company_sales_process_settings setting
JOIN public.companies company ON company.id=setting.company_id
UNION ALL
SELECT 'pos_retail_direct_return_preflight_runtime_boundary',
  CASE WHEN NOT EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))
    AND NOT EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION'))
    THEN 'PASS' ELSE 'BLOCKER' END,
  (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))+
  (SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')),
  jsonb_build_object('activeFinanceQueue',(SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')),
    'nonterminalOffline',(SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')));
