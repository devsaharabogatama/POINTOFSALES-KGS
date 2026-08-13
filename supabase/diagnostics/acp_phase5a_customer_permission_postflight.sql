-- ACP-5A postflight: Customer permission enforcement closure.
-- SAFETY: SELECT-only aggregate checks.

WITH required_routines(routine_name) AS (
  VALUES ('get_contacts_customers'),('get_pos_customer_references'),
    ('get_finance_customer_balance_references'),
    ('get_sales_document_customer_references'),
    ('get_sales_return_customer_references'),
    ('export_contacts_customer_categories'),('save_customer_category'),
    ('save_customer_with_pricelist')
), routine_state AS (
  SELECT procedure.oid,procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.proname IN(SELECT routine_name FROM required_routines)
    AND (procedure.proname<>'save_customer_category' OR procedure.pronargs=4)
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::BIGINT violation_rows,jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260812220000'

  UNION ALL
  SELECT 'customer_permission_enforced',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED'
      AND supported_capabilities @> ARRAY['VIEW','MANAGE','EXPORT','IMPORT']::TEXT[])
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED'
      AND supported_capabilities @> ARRAY['VIEW','MANAGE','EXPORT','IMPORT']::TEXT[])
      THEN 0 ELSE 1 END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog WHERE permission_key='contacts.customers'

  UNION ALL
  SELECT 'required_customer_routines',
    CASE WHEN count(DISTINCT routine.proname)=(SELECT count(*) FROM required_routines)
      THEN 'PASS' ELSE 'FAIL' END,
    ((SELECT count(*) FROM required_routines)-count(DISTINCT routine.proname))::BIGINT,
    jsonb_build_object('expected',(SELECT count(*) FROM required_routines),
      'routine_names',COALESCE(jsonb_agg(DISTINCT routine.proname ORDER BY routine.proname),'[]'::JSONB))
  FROM routine_state routine

  UNION ALL
  SELECT 'customer_runtime_permission_hooks',
    CASE WHEN count(*) FILTER(WHERE
      definition ILIKE '%contacts.customers%')>=4 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*) FILTER(WHERE
      definition ILIKE '%contacts.customers%')>=4 THEN 0 ELSE 1 END,
    jsonb_build_object('hooked_rows',count(*) FILTER(WHERE
      definition ILIKE '%contacts.customers%'))
  FROM routine_state

  UNION ALL
  SELECT 'browser_customer_table_boundary',
    CASE WHEN count(*) FILTER(WHERE readable OR writable)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE readable OR writable),
    jsonb_build_object('readable',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE readable),'[]'::JSONB),'writable',COALESCE(
      jsonb_agg(relation_name) FILTER(WHERE writable),'[]'::JSONB))
  FROM (SELECT relation_name,
      has_table_privilege('authenticated',format('public.%I',relation_name),'SELECT') readable,
      has_table_privilege('authenticated',format('public.%I',relation_name),'INSERT,UPDATE,DELETE') writable
    FROM (VALUES('customers'),('customer_categories'),
      ('customer_master_audit'),('customer_category_audit')) relation(relation_name)
  ) privilege_state

  UNION ALL
  SELECT 'browser_customer_rpc_boundary',
    CASE WHEN count(*) FILTER(WHERE NOT has_function_privilege(
      'authenticated',oid,'EXECUTE'))=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE NOT has_function_privilege('authenticated',oid,'EXECUTE')),
    jsonb_build_object('routine_rows',count(*))
  FROM routine_state

  UNION ALL
  SELECT 'legacy_customer_mutation_execution',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticated_executable_rows',count(*))
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND (
    procedure.proname IN('save_customer','save_customer_with_parent')
    OR (procedure.proname='save_customer_category' AND procedure.pronargs=5))
    AND has_function_privilege('authenticated',procedure.oid,'EXECUTE')

  UNION ALL
  SELECT 'customer_import_permission_hook',
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-4)::BIGINT,jsonb_build_object('routine_rows',count(*))
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND procedure.proname IN(
    'create_master_import_job','stage_master_import_rows',
    'validate_master_import_job','commit_master_import_job')
    AND pg_get_functiondef(procedure.oid) ILIKE
      '%acp_require_customer_import_if_needed%'

  UNION ALL
  SELECT 'pos_quick_create_independence',
    CASE WHEN count(*)=1 AND bool_and(definition ILIKE '%cashier_sessions%'
      AND definition ILIKE '%status%OPEN%'
      AND definition NOT ILIKE '%contacts.customers%')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(definition ILIKE '%cashier_sessions%'
      AND definition ILIKE '%status%OPEN%'
      AND definition NOT ILIKE '%contacts.customers%') THEN 0 ELSE 1 END,
    jsonb_build_object('routine_rows',count(*))
  FROM (SELECT pg_get_functiondef(procedure.oid) definition
    FROM pg_proc procedure JOIN pg_namespace namespace
      ON namespace.oid=procedure.pronamespace
    WHERE namespace.nspname='public'
      AND procedure.proname='quick_create_pos_customer') quick_create

  UNION ALL
  SELECT 'customer_tenant_reference_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('row_count',count(*))
  FROM public.customers customer
  LEFT JOIN public.customer_categories category
    ON category.company_id=customer.company_id
   AND category.id=customer.customer_category_id
  LEFT JOIN public.customers parent ON parent.company_id=customer.company_id
    AND parent.id=customer.parent_customer_id
  LEFT JOIN public.pricelists pricelist
    ON pricelist.company_id=customer.company_id
   AND pricelist.id=customer.default_pricelist_id
  WHERE category.id IS NULL
    OR (customer.parent_customer_id IS NOT NULL AND parent.id IS NULL)
    OR (customer.default_pricelist_id IS NOT NULL AND pricelist.id IS NULL)

  UNION ALL
  SELECT 'customer_balance_cache_ledger_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('customer_count',count(*))
  FROM public.customers customer
  LEFT JOIN LATERAL(SELECT entry.balance_after
    FROM public.customer_balance_ledger_entries entry
    WHERE entry.company_id=customer.company_id AND entry.customer_id=customer.id
    ORDER BY entry.entry_no DESC LIMIT 1) balance ON TRUE
  WHERE customer.current_balance<>COALESCE(balance.balance_after,0)

  UNION ALL
  SELECT 'nonterminal_customer_category_import',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('job_count',count(*))
  FROM public.master_import_jobs WHERE import_type='CUSTOMER_CATEGORY'
    AND status NOT IN('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
