-- ACP-5A preflight: Customer management permission and shared-consumer boundary.
-- SAFETY: one SELECT statement; aggregate metadata only; no business identity.

WITH required_versions(version) AS (
  VALUES ('20260812210000')
), expected_relations(relation_name) AS (
  VALUES ('customers'),('customer_categories'),
    ('customer_master_audit'),('customer_category_audit')
), mutation_names(routine_name) AS (
  VALUES ('save_customer_category'),('save_customer'),
    ('save_customer_with_parent'),('save_customer_with_pricelist')
), mutation_routines AS (
  SELECT procedure.oid,procedure.proname,
    pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.proname IN(SELECT routine_name FROM mutation_names)
), latest_balance AS (
  SELECT DISTINCT ON(entry.company_id,entry.customer_id)
    entry.company_id,entry.customer_id,entry.balance_after
  FROM public.customer_balance_ledger_entries entry
  ORDER BY entry.company_id,entry.customer_id,entry.entry_no DESC
), checks AS (
  SELECT 'acp_phase4i_dependency'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE ledger.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(required.version ORDER BY required.version)
        FILTER(WHERE ledger.version IS NULL),'[]'::JSONB)) details
  FROM required_versions required
  LEFT JOIN private.kgs_schema_migrations ledger
    ON ledger.version=required.version

  UNION ALL
  SELECT 'customer_permission_catalog_state',
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE
      enforcement_status='SHADOW' AND is_customizable
      AND view_roles=ARRAY[
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','FINANCE','ACCOUNTING'
      ]::TEXT[]
      AND operator_roles=ARRAY[
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'
      ]::TEXT[]
      AND supported_capabilities @> ARRAY['VIEW','MANAGE','EXPORT']::TEXT[]
    )=1 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB),'capabilities',COALESCE(
        (SELECT to_jsonb(supported_capabilities)
         FROM public.access_permission_catalog
         WHERE permission_key='contacts.customers'),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='contacts.customers'

  UNION ALL
  SELECT 'canonical_customer_schema_state',
    CASE WHEN count(*) FILTER(WHERE relation.oid IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(expected.relation_name ORDER BY expected.relation_name)
        FILTER(WHERE relation.oid IS NULL),'[]'::JSONB))
  FROM expected_relations expected
  LEFT JOIN pg_class relation ON relation.relname=expected.relation_name
    AND relation.relnamespace='public'::regnamespace

  UNION ALL
  SELECT 'customer_runtime_permission_hook_state','SETUP',
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'
        AND definition ILIKE '%contacts.customers%'))
  FROM mutation_routines

  UNION ALL
  SELECT 'canonical_customer_composed_read_state','SETUP',
    jsonb_build_object('rpc_exists',to_regprocedure(
      'public.get_contacts_customers(boolean)') IS NOT NULL,
      'required_design',jsonb_build_array(
        'guard management list/detail with contacts.customers VIEW',
        'return Customer, category, parent, and Pricelist labels without exposing unrelated ledgers',
        'do not require Sales, POS, or Finance permissions for Customer management'))

  UNION ALL
  SELECT 'customer_direct_read_cutover_scope','REVIEW',
    jsonb_build_object('authenticated_read_relations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE readable),
      '[]'::JSONB),'required_design',jsonb_build_array(
        'replace Backoffice Customer and Category table reads with one VIEW-guarded composed RPC',
        'revoke direct SELECT only after active Backoffice consumers migrate',
        'preserve narrow reference APIs for independently authorized modules'))
  FROM (
    SELECT expected.relation_name,has_table_privilege(
      'authenticated',format('public.%I',expected.relation_name),'SELECT') readable
    FROM expected_relations expected
  ) privilege_state

  UNION ALL
  SELECT 'customer_authority_split','REVIEW',
    jsonb_build_object(
      'management_roles',jsonb_build_array(
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'),
      'view_only_roles',jsonb_build_array('FINANCE','ACCOUNTING'),
      'required_design',jsonb_build_array(
        'Customer identity/category/parent/Pricelist mutation requires contacts.customers MANAGE',
        'Finance credit and Customer Balance workflows keep their own maker-checker authority',
        'POS Cashier quick-create remains Store/session scoped and never grants Backoffice MANAGE'))

  UNION ALL
  SELECT 'customer_shared_consumer_scope','REVIEW',
    jsonb_build_object('consumer_paths',jsonb_build_array(
      'POS checkout and quick-create','Sales Pricelist and Return',
      'Finance Customer Balance and statement','Global Data Exchange'),
      'rule','each consumer must authorize its own permission; client purpose must never bypass contacts.customers')

  UNION ALL
  SELECT 'customer_category_import_capability_decision','REVIEW',
    jsonb_build_object(
      'current_customer_capabilities',COALESCE((
        SELECT to_jsonb(supported_capabilities)
        FROM public.access_permission_catalog
        WHERE permission_key='contacts.customers'),'[]'::JSONB),
      'current_import_type','CUSTOMER_CATEGORY',
      'required_decision','keep category import role-only or add explicit IMPORT capability before enforcement; never infer IMPORT from MANAGE')

  UNION ALL
  SELECT 'customer_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE writable)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('direct_write_relations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE writable),
      '[]'::JSONB))
  FROM (
    SELECT expected.relation_name,
      has_table_privilege('authenticated',format('public.%I',expected.relation_name),
        'INSERT,UPDATE,DELETE') writable
    FROM expected_relations expected
  ) write_state

  UNION ALL
  SELECT 'customer_mutation_routine_state',
    CASE WHEN count(DISTINCT proname)=(SELECT count(*) FROM mutation_names)
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',(SELECT count(*) FROM mutation_names),
      'routine_names',COALESCE(jsonb_agg(DISTINCT proname ORDER BY proname),
        '[]'::JSONB),'signature_rows',count(*))
  FROM mutation_routines

  UNION ALL
  SELECT 'customer_tenant_reference_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('orphan_or_cross_tenant_rows',count(*))
  FROM public.customers customer
  LEFT JOIN public.customer_categories category
    ON category.company_id=customer.company_id
   AND category.id=customer.customer_category_id
  LEFT JOIN public.customers parent
    ON parent.company_id=customer.company_id
   AND parent.id=customer.parent_customer_id
  LEFT JOIN public.pricelists pricelist
    ON pricelist.company_id=customer.company_id
   AND pricelist.id=customer.default_pricelist_id
  WHERE category.id IS NULL
     OR (customer.parent_customer_id IS NOT NULL AND parent.id IS NULL)
     OR (customer.default_pricelist_id IS NOT NULL AND pricelist.id IS NULL)

  UNION ALL
  SELECT 'invalid_customer_parent_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.customers customer
  JOIN public.customers parent ON parent.company_id=customer.company_id
    AND parent.id=customer.parent_customer_id
  WHERE customer.id=parent.id OR customer.is_system_customer
     OR parent.is_system_customer OR NOT parent.is_active
     OR parent.parent_customer_id IS NOT NULL
     OR EXISTS(SELECT 1 FROM public.customers child
       WHERE child.company_id=customer.company_id
         AND child.parent_customer_id=customer.id)

  UNION ALL
  SELECT 'invalid_customer_default_pricelist',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.customers customer
  JOIN public.pricelists pricelist ON pricelist.company_id=customer.company_id
    AND pricelist.id=customer.default_pricelist_id
  WHERE customer.is_system_customer OR NOT pricelist.is_active
     OR pricelist.scope<>'CUSTOMER'

  UNION ALL
  SELECT 'active_company_walk_in_customer_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('company_count',count(*))
  FROM (
    SELECT company.id
    FROM public.companies company
    LEFT JOIN public.customers customer ON customer.company_id=company.id
      AND customer.is_system_customer AND customer.is_active
      AND customer.customer_type='WALK_IN'
      AND upper(btrim(customer.code))='WALK-IN'
      AND customer.current_balance=0 AND customer.credit_limit=0
    WHERE company.status='ACTIVE'
    GROUP BY company.id HAVING count(customer.id)<>1
  ) invalid_company

  UNION ALL
  SELECT 'duplicate_normalized_customer_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicate_groups',count(*))
  FROM (
    SELECT customer.company_id,'CODE' identity_type,
      upper(regexp_replace(btrim(customer.code),'\s+',' ','g')) identity_value
    FROM public.customers customer GROUP BY customer.company_id,
      upper(regexp_replace(btrim(customer.code),'\s+',' ','g')) HAVING count(*)>1
    UNION ALL
    SELECT customer.company_id,'NAME',
      lower(regexp_replace(btrim(customer.name),'\s+',' ','g'))
    FROM public.customers customer GROUP BY customer.company_id,
      lower(regexp_replace(btrim(customer.name),'\s+',' ','g')) HAVING count(*)>1
  ) duplicate_group

  UNION ALL
  SELECT 'customer_balance_cache_ledger_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('customer_count',count(*))
  FROM public.customers customer
  LEFT JOIN latest_balance balance ON balance.company_id=customer.company_id
    AND balance.customer_id=customer.id
  WHERE customer.current_balance<>COALESCE(balance.balance_after,0)

  UNION ALL
  SELECT 'customer_category_nonterminal_import_jobs',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('job_count',count(*),'companies',count(DISTINCT company_id))
  FROM public.master_import_jobs
  WHERE import_type='CUSTOMER_CATEGORY'
    AND status NOT IN('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED')

  UNION ALL
  SELECT 'customer_runtime_inventory','INFO',jsonb_build_object(
    'companies',count(DISTINCT company_id),'customers',count(*),
    'active_customers',count(*) FILTER(WHERE is_active),
    'system_walk_in',count(*) FILTER(WHERE is_system_customer),
    'branch_customers',count(*) FILTER(WHERE parent_customer_id IS NOT NULL),
    'customers_with_pricelist',count(*) FILTER(WHERE default_pricelist_id IS NOT NULL),
    'customers_with_balance',count(*) FILTER(WHERE current_balance<>0))
  FROM public.customers

  UNION ALL
  SELECT 'customer_browser_rpc_execution_inventory','INFO',
    jsonb_build_object('routine_names',count(DISTINCT proname),
      'signature_rows',count(*),'authenticated_executable_rows',count(*) FILTER(
        WHERE has_function_privilege('authenticated',procedure.oid,'EXECUTE')),
      'quick_create_executable',COALESCE(bool_or(
        has_function_privilege('authenticated',procedure.oid,'EXECUTE')) FILTER(
          WHERE procedure.proname='quick_create_pos_customer'),FALSE))
  FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND procedure.proname IN(
    SELECT routine_name FROM mutation_names UNION ALL
    SELECT 'quick_create_pos_customer')
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2
  WHEN 'SETUP' THEN 3 WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
