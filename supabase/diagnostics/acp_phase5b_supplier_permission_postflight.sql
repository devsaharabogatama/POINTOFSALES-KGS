-- ACP-5B postflight: Supplier permission enforcement closure.
-- SAFETY: SELECT-only aggregate checks.

WITH required_routines(routine_name) AS (
  VALUES ('get_contacts_suppliers'),('save_contacts_supplier'),
    ('save_contacts_product_supplier'),
    ('get_supplier_order_supplier_references'),
    ('get_purchase_return_supplier_references'),
    ('get_goods_receipt_supplier_references'),
    ('get_pos_purchase_return_supplier_references'),
    ('get_supplier_invoice_supplier_references'),
    ('get_supplier_payment_supplier_references'),
    ('export_contacts_suppliers'),('export_contacts_product_suppliers')
), routine_state AS (
  SELECT procedure.oid,procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.proname IN(SELECT routine_name FROM required_routines)
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::BIGINT violation_rows,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260812230000'

  UNION ALL
  SELECT 'supplier_permission_enforced',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED'
      AND supported_capabilities @> ARRAY[
        'VIEW','MANAGE','EXPORT','IMPORT']::TEXT[])
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED'
      AND supported_capabilities @> ARRAY[
        'VIEW','MANAGE','EXPORT','IMPORT']::TEXT[])
      THEN 0 ELSE 1 END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog WHERE permission_key='contacts.suppliers'

  UNION ALL
  SELECT 'required_supplier_routines',
    CASE WHEN count(DISTINCT proname)=(SELECT count(*) FROM required_routines)
      THEN 'PASS' ELSE 'FAIL' END,
    ((SELECT count(*) FROM required_routines)-count(DISTINCT proname))::BIGINT,
    jsonb_build_object('expected',(SELECT count(*) FROM required_routines),
      'routine_names',COALESCE(jsonb_agg(DISTINCT proname ORDER BY proname),
        '[]'::JSONB))
  FROM routine_state

  UNION ALL
  SELECT 'supplier_runtime_permission_hooks',
    CASE WHEN count(*) FILTER(WHERE
      definition ILIKE '%contacts.suppliers%')>=5 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*) FILTER(WHERE
      definition ILIKE '%contacts.suppliers%')>=5 THEN 0 ELSE 1 END,
    jsonb_build_object('hooked_rows',count(*) FILTER(WHERE
      definition ILIKE '%contacts.suppliers%'))
  FROM routine_state

  UNION ALL
  SELECT 'browser_supplier_table_boundary',
    CASE WHEN count(*) FILTER(WHERE readable OR writable)=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE readable OR writable),
    jsonb_build_object('readable',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE readable),'[]'::JSONB),'writable',COALESCE(
      jsonb_agg(relation_name) FILTER(WHERE writable),'[]'::JSONB))
  FROM (SELECT relation_name,
      has_table_privilege('authenticated',format('public.%I',relation_name),'SELECT') readable,
      has_table_privilege('authenticated',format('public.%I',relation_name),
        'INSERT,UPDATE,DELETE') writable
    FROM (VALUES('suppliers'),('product_suppliers'),
      ('supplier_master_audit'),('product_supplier_audit')) relation(relation_name)
  ) privilege_state

  UNION ALL
  SELECT 'browser_supplier_rpc_boundary',
    CASE WHEN count(*) FILTER(WHERE NOT has_function_privilege(
      'authenticated',oid,'EXECUTE'))=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE NOT has_function_privilege(
      'authenticated',oid,'EXECUTE')),
    jsonb_build_object('routine_rows',count(*))
  FROM routine_state

  UNION ALL
  SELECT 'legacy_supplier_mutation_execution',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticated_executable_rows',count(*))
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.proname IN('save_supplier','save_product_supplier')
    AND has_function_privilege('authenticated',procedure.oid,'EXECUTE')

  UNION ALL
  SELECT 'supplier_import_permission_hook',
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-4)::BIGINT,jsonb_build_object('routine_rows',count(*))
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND procedure.proname IN(
    'create_master_import_job','stage_master_import_rows',
    'validate_master_import_job','commit_master_import_job')
    AND pg_get_functiondef(procedure.oid) ILIKE
      '%acp_require_supplier_import_if_needed%'

  UNION ALL
  SELECT 'supplier_tenant_reference_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('row_count',count(*))
  FROM public.product_suppliers relation
  LEFT JOIN public.products product ON product.company_id=relation.company_id
    AND product.id=relation.product_id
  LEFT JOIN public.suppliers supplier ON supplier.company_id=relation.company_id
    AND supplier.id=relation.supplier_id
  LEFT JOIN public.product_uoms product_uom
    ON product_uom.company_id=relation.company_id
   AND product_uom.product_id=relation.product_id
   AND product_uom.uom_id=relation.purchase_uom_id
  WHERE product.id IS NULL OR supplier.id IS NULL OR product_uom.id IS NULL

  UNION ALL
  SELECT 'multiple_active_preferred_supplier',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('product_count',count(*))
  FROM (SELECT company_id,product_id FROM public.product_suppliers
    WHERE is_active AND is_preferred_supplier
    GROUP BY company_id,product_id HAVING count(*)>1) duplicate_preferred

  UNION ALL
  SELECT 'nonterminal_supplier_import',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('job_count',count(*))
  FROM public.master_import_jobs WHERE import_type IN('SUPPLIER','PRODUCT_SUPPLIER')
    AND status NOT IN('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
