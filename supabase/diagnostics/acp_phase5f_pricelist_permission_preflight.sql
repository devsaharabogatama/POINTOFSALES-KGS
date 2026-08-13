-- ACP-5F preflight: Pricelist management and independent POS pricing authority.
-- SAFETY: one SELECT statement; aggregate metadata only; no business identity.

WITH required_versions(version) AS (
  VALUES ('20260722070000'),('20260722100000'),('20260724010000'),
    ('20260729100000'),('20260730010000'),('20260812220000'),
    ('20260813020000')
), expected_relations(relation_name) AS (
  VALUES ('pricelists'),('pricelist_store_assignments'),
    ('pricelist_rules'),('pricelist_master_audit')
), management_routine AS (
  SELECT procedure.oid,procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure
  WHERE procedure.oid=to_regprocedure(
    'public.save_reusable_pricelist_with_rules(uuid,bigint,text,text,integer,boolean,boolean,uuid[],timestamp with time zone,timestamp with time zone,boolean,text,jsonb)')
), pricing_routines AS (
  SELECT procedure.oid,procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure
  WHERE procedure.pronamespace='private'::regnamespace
    AND procedure.proname IN (
      'resolve_pos_sale_price','resolve_pos_sale_price_online_core')
), checks AS (
  SELECT 'acp_phase5f_dependencies'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE ledger.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(required.version ORDER BY required.version)
        FILTER(WHERE ledger.version IS NULL),'[]'::JSONB)) details
  FROM required_versions required
  LEFT JOIN private.kgs_schema_migrations ledger
    ON ledger.version=required.version

  UNION ALL
  SELECT 'pricelist_permission_catalog_state',
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
         WHERE permission_key='sales.pricelists'),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='sales.pricelists'

  UNION ALL
  SELECT 'canonical_pricelist_schema_state',
    CASE WHEN count(*) FILTER(WHERE relation.oid IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(expected.relation_name ORDER BY expected.relation_name)
        FILTER(WHERE relation.oid IS NULL),'[]'::JSONB))
  FROM expected_relations expected
  LEFT JOIN pg_class relation ON relation.relname=expected.relation_name
    AND relation.relnamespace='public'::regnamespace

  UNION ALL
  SELECT 'canonical_pricelist_composed_read_state','SETUP',
    jsonb_build_object('rpc_exists',to_regprocedure(
      'public.get_sales_pricelists()') IS NOT NULL,
      'required_design',jsonb_build_array(
        'guard Backoffice list/detail with sales.pricelists VIEW',
        'return Pricelist, active rules, Store assignments and narrow labels',
        'do not expose Customer, Sale, Payment or Finance ledgers'))

  UNION ALL
  SELECT 'pricelist_direct_read_cutover_scope','REVIEW',
    jsonb_build_object('authenticated_read_relations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE readable),
      '[]'::JSONB),'required_design',jsonb_build_array(
        'replace Backoffice table reads with one VIEW-guarded composed RPC',
        'move POS online Pricelist reads to a Cashier-session reference RPC',
        'retain the Offline catalog snapshot as an independent policy path',
        'revoke direct SELECT only after all active consumers migrate'))
  FROM (
    SELECT expected.relation_name,has_table_privilege(
      'authenticated',format('public.%I',expected.relation_name),'SELECT') readable
    FROM expected_relations expected
  ) privilege_state

  UNION ALL
  SELECT 'pricelist_channel_authority_split','REVIEW',
    jsonb_build_object(
      'management_roles',jsonb_build_array(
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'),
      'view_only_roles',jsonb_build_array('FINANCE','ACCOUNTING'),
      'required_design',jsonb_build_array(
        'Pricelist identity, rule and Store scope mutation require MANAGE',
        'Customer assignment remains contacts.customers MANAGE',
        'Cashier may select an eligible Pricelist without Backoffice MANAGE',
        'EXPORT never follows VIEW implicitly'))

  UNION ALL
  SELECT 'pricelist_pos_consumer_scope','REVIEW',
    jsonb_build_object('required_design',jsonb_build_array(
      'POS references require an active open Cashier session and Store scope',
      'explicit override accepts only eligible active Global Pricelists',
      'Customer default remains server-resolved and reusable',
      'the client never supplies authoritative price, rule or eligibility'))

  UNION ALL
  SELECT 'pricelist_offline_consumer_scope','REVIEW',
    jsonb_build_object('snapshot_rpc_exists',EXISTS(
      SELECT 1 FROM pg_proc procedure
      WHERE procedure.pronamespace='public'::regnamespace
        AND procedure.proname='get_pos_offline_catalog_snapshot'),
      'required_design',jsonb_build_array(
        'Offline catalog remains guarded by Offline entitlement and Terminal policy',
        'cached Pricelist and rule data is immutable input to retained checkout',
        'Backoffice restriction must never widen or break Offline authority'))

  UNION ALL
  SELECT 'pricelist_export_import_contract','REVIEW',
    jsonb_build_object('required_design',jsonb_build_array(
      'Pricelist export requires sales.pricelists EXPORT',
      'no generic Pricelist import is opened in ACP-5F',
      'Customer assignment export remains Customer-owned data'))

  UNION ALL
  SELECT 'pricelist_runtime_permission_hook_state','SETUP',
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'
        AND definition ILIKE '%sales.pricelists%'),
      'routine_names',COALESCE(jsonb_agg(proname ORDER BY proname),
        '[]'::JSONB))
  FROM management_routine

  UNION ALL
  SELECT 'pricelist_pricing_resolver_state',
    CASE WHEN count(DISTINCT proname)=2
      AND count(*) FILTER(WHERE definition ILIKE '%pricelist_rules%')>0
      AND count(*) FILTER(WHERE definition ILIKE '%default_pricelist_id%')>0
      AND count(*) FILTER(WHERE definition ILIKE '%pricelist_store_assignments%')>0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routine_rows',count(*),
      'routine_names',COALESCE(jsonb_agg(DISTINCT proname ORDER BY proname),
        '[]'::JSONB),'server_rule_resolution',count(*) FILTER(
        WHERE definition ILIKE '%pricelist_rules%')>0,
      'customer_default_resolution',count(*) FILTER(
        WHERE definition ILIKE '%default_pricelist_id%')>0,
      'store_eligibility_resolution',count(*) FILTER(
        WHERE definition ILIKE '%pricelist_store_assignments%')>0)
  FROM pricing_routines

  UNION ALL
  SELECT 'pricelist_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE writable)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('direct_write_relations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE writable),
      '[]'::JSONB))
  FROM (
    SELECT expected.relation_name,has_table_privilege(
      'authenticated',format('public.%I',expected.relation_name),
      'INSERT,UPDATE,DELETE') writable
    FROM expected_relations expected
  ) write_state

  UNION ALL
  SELECT 'pricelist_mutation_routine_state',
    CASE WHEN count(*)=1
      AND count(*) FILTER(WHERE has_function_privilege(
        'authenticated',oid,'EXECUTE'))=1
      AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routine_rows',count(*),
      'authenticated_executable_rows',count(*) FILTER(WHERE
        has_function_privilege('authenticated',oid,'EXECUTE')),
      'anon_executable_rows',count(*) FILTER(WHERE
        has_function_privilege('anon',oid,'EXECUTE')))
  FROM management_routine

  UNION ALL
  SELECT 'pricelist_override_tenant_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.user_company_permission_overrides override_row
  LEFT JOIN public.company_memberships membership
    ON membership.company_id=override_row.company_id
   AND membership.user_id=override_row.user_id
  WHERE override_row.permission_key='sales.pricelists'
    AND membership.user_id IS NULL

  UNION ALL
  SELECT 'duplicate_normalized_pricelist_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicate_groups',count(*))
  FROM (
    SELECT company_id,lower(regexp_replace(btrim(name),'\s+',' ','g')) identity
    FROM public.pricelists GROUP BY company_id,identity HAVING count(*)>1
    UNION ALL
    SELECT company_id,upper(regexp_replace(btrim(code),'\s+',' ','g')) identity
    FROM public.pricelists GROUP BY company_id,identity HAVING count(*)>1
  ) duplicate_group

  UNION ALL
  SELECT 'active_company_default_global_pricelist',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BACKFILL' END,
    jsonb_build_object('company_count',count(*))
  FROM (
    SELECT company.id,count(pricelist.id) FILTER(WHERE pricelist.scope='GLOBAL'
      AND pricelist.is_active AND pricelist.is_default) default_count
    FROM public.companies company
    LEFT JOIN public.pricelists pricelist ON pricelist.company_id=company.id
    WHERE company.status='ACTIVE' GROUP BY company.id
  ) company_default WHERE default_count<>1

  UNION ALL
  SELECT 'invalid_customer_default_pricelist',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.customers customer
  LEFT JOIN public.pricelists pricelist
    ON pricelist.company_id=customer.company_id
   AND pricelist.id=customer.default_pricelist_id
  WHERE (customer.is_system_customer AND customer.default_pricelist_id IS NOT NULL)
     OR (customer.default_pricelist_id IS NOT NULL AND (
       pricelist.id IS NULL OR pricelist.scope<>'CUSTOMER' OR NOT pricelist.is_active))

  UNION ALL
  SELECT 'invalid_pricelist_store_scope',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.pricelist_store_assignments assignment
  LEFT JOIN public.pricelists pricelist
    ON pricelist.company_id=assignment.company_id
   AND pricelist.id=assignment.pricelist_id
  LEFT JOIN public.stores store
    ON store.company_id=assignment.company_id AND store.id=assignment.store_id
  WHERE pricelist.id IS NULL OR store.id IS NULL OR pricelist.applies_all_stores

  UNION ALL
  SELECT 'invalid_active_pricelist_rule',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.pricelist_rules rule
  LEFT JOIN public.pricelists pricelist
    ON pricelist.company_id=rule.company_id AND pricelist.id=rule.pricelist_id
  LEFT JOIN public.products product
    ON product.company_id=rule.company_id AND product.id=rule.product_id
  LEFT JOIN public.product_uoms product_uom
    ON product_uom.company_id=rule.company_id
   AND product_uom.id=rule.product_uom_id
   AND product_uom.product_id=rule.product_id
  WHERE rule.is_active AND (
    pricelist.id IS NULL OR product.id IS NULL OR product_uom.id IS NULL
    OR (pricelist.scope='CUSTOMER' AND rule.min_qty<>1))

  UNION ALL
  SELECT 'posted_sale_pricelist_snapshot_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.sales_details detail
  LEFT JOIN public.pricelists pricelist
    ON pricelist.company_id=detail.company_id AND pricelist.id=detail.pricelist_id
  LEFT JOIN public.pricelist_rules rule
    ON rule.company_id=detail.company_id AND rule.id=detail.pricelist_rule_id
  WHERE (detail.pricelist_id IS NOT NULL AND pricelist.id IS NULL)
     OR (detail.pricelist_rule_id IS NOT NULL AND (
       rule.id IS NULL OR rule.pricelist_id IS DISTINCT FROM detail.pricelist_id))

  UNION ALL
  SELECT 'pricelist_runtime_inventory','INFO',
    jsonb_build_object(
      'companies',(SELECT count(DISTINCT company_id) FROM public.pricelists),
      'pricelists',(SELECT count(*) FROM public.pricelists),
      'active_global',(SELECT count(*) FROM public.pricelists
        WHERE is_active AND scope='GLOBAL'),
      'active_customer',(SELECT count(*) FROM public.pricelists
        WHERE is_active AND scope='CUSTOMER'),
      'active_rules',(SELECT count(*) FROM public.pricelist_rules
        WHERE is_active),
      'store_assignments',(SELECT count(*)
        FROM public.pricelist_store_assignments),
      'customers_assigned',(SELECT count(*) FROM public.customers
        WHERE default_pricelist_id IS NOT NULL),
      'posted_sale_lines_with_pricelist',(SELECT count(*)
        FROM public.sales_details WHERE pricelist_id IS NOT NULL),
      'override_rows',(SELECT count(*)
        FROM public.user_company_permission_overrides
        WHERE permission_key='sales.pricelists'))
)
SELECT check_name,status,details
FROM checks
ORDER BY CASE status
  WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2 WHEN 'SETUP' THEN 3
  WHEN 'BACKFILL' THEN 4 WHEN 'PASS' THEN 5 ELSE 6 END,check_name;
