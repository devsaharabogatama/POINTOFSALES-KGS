-- ACP-5F postflight: Pricelist effective permission enforcement.
-- SAFETY: SELECT-only; aggregate metadata only.

WITH expected_relations(relation_name) AS (
  VALUES ('pricelists'),('pricelist_store_assignments'),
    ('pricelist_rules'),('pricelist_master_audit')
), expected_routines(signature) AS (
  VALUES ('public.get_sales_pricelists(boolean)'),
    ('public.get_pos_pricelist_references(uuid)'),
    ('public.export_sales_pricelists()'),
    ('public.save_reusable_pricelist_with_rules(uuid,bigint,text,text,integer,boolean,boolean,uuid[],timestamp with time zone,timestamp with time zone,boolean,text,jsonb)')
), guarded_routines AS (
  SELECT procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure WHERE procedure.oid IN(
    to_regprocedure('public.get_sales_pricelists(boolean)'),
    to_regprocedure('public.export_sales_pricelists()'),
    to_regprocedure('public.save_reusable_pricelist_with_rules(uuid,bigint,text,text,integer,boolean,boolean,uuid[],timestamp with time zone,timestamp with time zone,boolean,text,jsonb)'))
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    count(*) FILTER(WHERE version<>'20260813030000') violation_rows,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260813030000'

  UNION ALL
  SELECT 'pricelist_permission_enforced',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED')
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE enforcement_status<>'ENFORCED'),
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog WHERE permission_key='sales.pricelists'

  UNION ALL
  SELECT 'required_pricelist_routines',
    CASE WHEN count(*) FILTER(WHERE to_regprocedure(signature) IS NULL)=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE to_regprocedure(signature) IS NULL),
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(signature ORDER BY signature)
        FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'::JSONB))
  FROM expected_routines

  UNION ALL
  SELECT 'pricelist_runtime_permission_hooks',
    CASE WHEN count(*)=3 AND count(*) FILTER(WHERE
      definition ILIKE '%acp_require_permission_capability%'
      AND definition ILIKE '%sales.pricelists%')=3
      THEN 'PASS' ELSE 'FAIL' END,
    3-count(*) FILTER(WHERE definition ILIKE
      '%acp_require_permission_capability%'
      AND definition ILIKE '%sales.pricelists%'),
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'
        AND definition ILIKE '%sales.pricelists%'))
  FROM guarded_routines

  UNION ALL
  SELECT 'browser_pricelist_table_boundary',
    CASE WHEN count(*) FILTER(WHERE readable OR writable)=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE readable OR writable),
    jsonb_build_object('readable',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE readable),'[]'::JSONB),'writable',COALESCE(
      jsonb_agg(relation_name) FILTER(WHERE writable),'[]'::JSONB))
  FROM (SELECT relation_name,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'SELECT') readable,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'INSERT,UPDATE,DELETE') writable FROM expected_relations) privilege_state

  UNION ALL
  SELECT 'private_pricelist_core_boundary',
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE
      has_function_privilege('authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE has_function_privilege(
      'authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE')),
    jsonb_build_object('core_rows',count(*))
  FROM pg_proc procedure WHERE procedure.pronamespace='private'::regnamespace
    AND procedure.proname='acp5f_save_reusable_pricelist_with_rules_core'

  UNION ALL
  SELECT 'legacy_pricelist_mutation_boundary',
    CASE WHEN procedure.oid IS NOT NULL
      AND NOT has_function_privilege('authenticated',procedure.oid,'EXECUTE')
      AND NOT has_function_privilege('anon',procedure.oid,'EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN procedure.oid IS NULL OR
      has_function_privilege('authenticated',procedure.oid,'EXECUTE') OR
      has_function_privilege('anon',procedure.oid,'EXECUTE') THEN 1 ELSE 0 END,
    jsonb_build_object('routine_exists',procedure.oid IS NOT NULL,
      'authenticated_execute',CASE WHEN procedure.oid IS NULL THEN NULL ELSE
        has_function_privilege('authenticated',procedure.oid,'EXECUTE') END)
  FROM pg_proc procedure WHERE procedure.oid=to_regprocedure(
    'public.save_reusable_pricelist_with_rules(uuid,bigint,text,text,text,integer,boolean,boolean,uuid[],timestamp with time zone,timestamp with time zone,boolean,text,jsonb)')

  UNION ALL
  SELECT 'public_pricelist_rpc_boundary',
    CASE WHEN count(*) FILTER(WHERE procedure.oid IS NULL)=0
      AND count(*) FILTER(WHERE procedure.oid IS NOT NULL AND
        NOT has_function_privilege('authenticated',procedure.oid,'EXECUTE'))=0
      AND count(*) FILTER(WHERE procedure.oid IS NOT NULL AND
        has_function_privilege('anon',procedure.oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE procedure.oid IS NULL OR
      NOT has_function_privilege('authenticated',procedure.oid,'EXECUTE') OR
      has_function_privilege('anon',procedure.oid,'EXECUTE')),
    jsonb_build_object('expected',count(*))
  FROM expected_routines expected
  LEFT JOIN pg_proc procedure ON procedure.oid=to_regprocedure(expected.signature)

  UNION ALL
  SELECT 'active_company_default_global_pricelist',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('company_count',count(*))
  FROM (SELECT company.id,count(pricelist.id) FILTER(WHERE
      pricelist.scope='GLOBAL' AND pricelist.is_active
      AND pricelist.is_default) default_count
    FROM public.companies company LEFT JOIN public.pricelists pricelist
      ON pricelist.company_id=company.id
    WHERE company.status='ACTIVE' GROUP BY company.id) company_state
  WHERE default_count<>1

  UNION ALL
  SELECT 'invalid_customer_default_pricelist',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('row_count',count(*))
  FROM public.customers customer LEFT JOIN public.pricelists pricelist
    ON pricelist.company_id=customer.company_id
   AND pricelist.id=customer.default_pricelist_id
  WHERE (customer.is_system_customer AND customer.default_pricelist_id IS NOT NULL)
     OR (customer.default_pricelist_id IS NOT NULL AND (
       pricelist.id IS NULL OR pricelist.scope<>'CUSTOMER' OR NOT pricelist.is_active))

  UNION ALL
  SELECT 'posted_sale_pricelist_snapshot_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('row_count',count(*))
  FROM public.sales_details detail LEFT JOIN public.pricelists pricelist
    ON pricelist.company_id=detail.company_id AND pricelist.id=detail.pricelist_id
  LEFT JOIN public.pricelist_rules rule
    ON rule.company_id=detail.company_id AND rule.id=detail.pricelist_rule_id
  WHERE (detail.pricelist_id IS NOT NULL AND pricelist.id IS NULL)
     OR (detail.pricelist_rule_id IS NOT NULL AND (
       rule.id IS NULL OR rule.pricelist_id IS DISTINCT FROM detail.pricelist_id))

  UNION ALL
  SELECT 'pricelist_resolver_preserved',
    CASE WHEN count(DISTINCT procedure.proname)=2
      AND count(*) FILTER(WHERE pg_get_functiondef(procedure.oid)
        ILIKE '%pricelist_rules%')>0 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(DISTINCT procedure.proname)=2 THEN 0 ELSE 1 END,
    jsonb_build_object('routine_rows',count(*),'routine_names',COALESCE(
      jsonb_agg(DISTINCT procedure.proname ORDER BY procedure.proname),
      '[]'::JSONB))
  FROM pg_proc procedure WHERE procedure.pronamespace='private'::regnamespace
    AND procedure.proname IN(
      'resolve_pos_sale_price','resolve_pos_sale_price_online_core')

  UNION ALL
  SELECT 'pricelist_runtime_inventory','INFO',0,
    jsonb_build_object('pricelists',(SELECT count(*) FROM public.pricelists),
      'active_rules',(SELECT count(*) FROM public.pricelist_rules
        WHERE is_active),'store_assignments',(SELECT count(*)
        FROM public.pricelist_store_assignments),'customers_assigned',
      (SELECT count(*) FROM public.customers
        WHERE default_pricelist_id IS NOT NULL),'override_rows',(SELECT count(*)
        FROM public.user_company_permission_overrides
        WHERE permission_key='sales.pricelists'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
