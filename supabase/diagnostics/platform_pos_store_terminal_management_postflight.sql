-- Platform POS Store/Terminal management postflight. SELECT-only.
WITH checks AS (
  SELECT 'migration_ledger' AS check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
    jsonb_build_object('ledgerRows',count(*)) AS details
  FROM private.kgs_schema_migrations WHERE version='20260821120000'
  UNION ALL
  SELECT 'required_platform_pos_routines',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('routineRows',count(*),'expected',3)
  FROM pg_proc routine JOIN pg_namespace schema ON schema.oid=routine.pronamespace
  WHERE schema.nspname='public' AND routine.proname IN(
    'get_platform_pos_setup','save_platform_pos_store','save_platform_pos_terminal')
  UNION ALL
  SELECT 'platform_pos_master_version_columns',
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('columnRows',count(*),'expected',4)
  FROM information_schema.columns
  WHERE table_schema='public' AND ((table_name='stores' AND column_name IN(
    'operational_master_version','operational_updated_by')) OR
    (table_name='pos_terminals' AND column_name IN(
    'operational_master_version','operational_updated_by')))
  UNION ALL
  SELECT 'browser_platform_pos_write_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('directWriteRows',count(*))
  FROM information_schema.role_table_grants
  WHERE grantee='authenticated' AND table_schema='public'
    AND table_name IN('stores','pos_terminals','platform_pos_master_audit')
    AND privilege_type IN('INSERT','UPDATE','DELETE')
  UNION ALL
  SELECT 'active_terminal_store_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.pos_terminals terminal LEFT JOIN public.stores store
    ON store.id=terminal.store_id AND store.company_id=terminal.company_id
  WHERE terminal.status='ACTIVE' AND (store.id IS NULL OR store.status<>'ACTIVE')
  UNION ALL
  SELECT 'open_session_operational_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.cashier_sessions session
  LEFT JOIN public.pos_terminals terminal ON terminal.id=session.pos_id
    AND terminal.company_id=session.company_id
  LEFT JOIN public.stores store ON store.id=session.store_id
    AND store.company_id=session.company_id
  WHERE session.status='OPEN'::public.session_status
    AND (terminal.id IS NULL OR terminal.status<>'ACTIVE' OR store.id IS NULL OR store.status<>'ACTIVE')
  UNION ALL
  SELECT 'duplicate_store_code',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('duplicateGroups',count(*))
  FROM (SELECT company_id,upper(regexp_replace(btrim(store_code),'\s+',' ','g'))
    FROM public.stores GROUP BY 1,2 HAVING count(*)>1) duplicate
  UNION ALL
  SELECT 'duplicate_terminal_code_per_store',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('duplicateGroups',count(*))
  FROM (SELECT company_id,store_id,upper(regexp_replace(btrim(pos_code),'\s+',' ','g'))
    FROM public.pos_terminals GROUP BY 1,2,3 HAVING count(*)>1) duplicate
  UNION ALL
  SELECT 'platform_pos_runtime_inventory','INFO',jsonb_build_object(
    'companies',(SELECT count(*) FROM public.companies WHERE status='ACTIVE'),
    'activeStores',(SELECT count(*) FROM public.stores WHERE status='ACTIVE'),
    'activeTerminals',(SELECT count(*) FROM public.pos_terminals WHERE status='ACTIVE'),
    'openSessions',(SELECT count(*) FROM public.cashier_sessions WHERE status='OPEN'::public.session_status),
    'auditRows',(SELECT count(*) FROM public.platform_pos_master_audit))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
