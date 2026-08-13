-- ACP-5B preflight: Supplier and Product-Supplier permission boundary.
-- SAFETY: one SELECT statement; aggregate metadata only; no business identity.

WITH required_versions(version) AS (
  VALUES ('20260812220000')
), expected_relations(relation_name) AS (
  VALUES ('suppliers'),('product_suppliers'),
    ('supplier_master_audit'),('product_supplier_audit')
), mutation_names(routine_name) AS (
  VALUES ('save_supplier'),('save_product_supplier')
), mutation_routines AS (
  SELECT procedure.oid,procedure.proname,
    pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.proname IN(SELECT routine_name FROM mutation_names)
), checks AS (
  SELECT 'acp_phase5a_dependency'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE ledger.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(required.version ORDER BY required.version)
        FILTER(WHERE ledger.version IS NULL),'[]'::JSONB)) details
  FROM required_versions required
  LEFT JOIN private.kgs_schema_migrations ledger
    ON ledger.version=required.version

  UNION ALL
  SELECT 'supplier_permission_catalog_state',
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE
      enforcement_status='SHADOW' AND is_customizable
      AND view_roles=ARRAY[
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN',
        'FINANCE','ACCOUNTING'
      ]::TEXT[]
      AND operator_roles=ARRAY[
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'
      ]::TEXT[]
      AND supported_capabilities @> ARRAY[
        'VIEW','MANAGE','EXPORT','IMPORT'
      ]::TEXT[]
    )=1 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB),'capabilities',COALESCE(
        (SELECT to_jsonb(supported_capabilities)
         FROM public.access_permission_catalog
         WHERE permission_key='contacts.suppliers'),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='contacts.suppliers'

  UNION ALL
  SELECT 'canonical_supplier_schema_state',
    CASE WHEN count(*) FILTER(WHERE relation.oid IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(expected.relation_name ORDER BY expected.relation_name)
        FILTER(WHERE relation.oid IS NULL),'[]'::JSONB))
  FROM expected_relations expected
  LEFT JOIN pg_class relation ON relation.relname=expected.relation_name
    AND relation.relnamespace='public'::regnamespace

  UNION ALL
  SELECT 'supplier_runtime_permission_hook_state','SETUP',
    jsonb_build_object('routine_names',count(DISTINCT proname),
      'signature_rows',count(*),'hooked_rows',count(*) FILTER(
        WHERE definition ILIKE '%acp_require_permission_capability%'
          AND definition ILIKE '%contacts.suppliers%'))
  FROM mutation_routines

  UNION ALL
  SELECT 'canonical_supplier_composed_read_state','SETUP',
    jsonb_build_object('rpc_exists',to_regprocedure(
      'public.get_contacts_suppliers(boolean)') IS NOT NULL,
      'required_design',jsonb_build_array(
        'guard Supplier management list/detail with contacts.suppliers VIEW',
        'return Supplier and Product-Supplier labels without unrelated Purchase or Finance documents',
        'keep bank reference inside the guarded management response'))

  UNION ALL
  SELECT 'supplier_direct_read_cutover_scope','REVIEW',
    jsonb_build_object('authenticated_read_relations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE readable),
      '[]'::JSONB),'required_design',jsonb_build_array(
        'replace Contacts Supplier and Product-Supplier table reads with one VIEW-guarded RPC',
        'revoke direct SELECT only after every active browser consumer is migrated',
        'preserve narrow reference APIs for Purchase, Product, and Finance'))
  FROM (
    SELECT expected.relation_name,has_table_privilege(
      'authenticated',format('public.%I',expected.relation_name),'SELECT') readable
    FROM expected_relations expected
  ) privilege_state

  UNION ALL
  SELECT 'supplier_authority_split','REVIEW',
    jsonb_build_object(
      'management_roles',jsonb_build_array(
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'),
      'view_only_roles',jsonb_build_array('FINANCE','ACCOUNTING'),
      'required_design',jsonb_build_array(
        'Supplier identity, bank reference, and Product-Supplier mutation require contacts.suppliers MANAGE',
        'Finance invoice and payment workflows retain their own maker-checker authority',
        'Purchase order and return workflows retain their own document authority'))

  UNION ALL
  SELECT 'supplier_shared_consumer_scope','REVIEW',
    jsonb_build_object('consumer_paths',jsonb_build_array(
      'Purchase Supplier Order and Purchase Return',
      'Finance Supplier Invoice, tolerance policy, and Supplier Payment',
      'Product management Product-Supplier reference',
      'Global Data Exchange Supplier and Product-Supplier'),
      'rule','each consumer authorizes its own key; client purpose never bypasses contacts.suppliers')

  UNION ALL
  SELECT 'supplier_import_export_contract','REVIEW',
    jsonb_build_object(
      'import_types',jsonb_build_array('SUPPLIER','PRODUCT_SUPPLIER'),
      'required_design',jsonb_build_array(
        'both fixed import types require contacts.suppliers IMPORT',
        'Supplier and Product-Supplier export require contacts.suppliers EXPORT',
        'generic import cannot mutate final Purchase, stock, AP, or payment history'))

  UNION ALL
  SELECT 'supplier_direct_write_boundary',
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
  SELECT 'supplier_mutation_routine_state',
    CASE WHEN count(DISTINCT proname)=(SELECT count(*) FROM mutation_names)
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',(SELECT count(*) FROM mutation_names),
      'routine_names',COALESCE(jsonb_agg(DISTINCT proname ORDER BY proname),
        '[]'::JSONB),'signature_rows',count(*),
      'authenticated_executable_rows',count(*) FILTER(WHERE
        has_function_privilege('authenticated',oid,'EXECUTE')))
  FROM mutation_routines

  UNION ALL
  SELECT 'supplier_tenant_reference_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('orphan_or_cross_tenant_rows',count(*))
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
  SELECT 'invalid_active_product_supplier_reference',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.product_suppliers relation
  JOIN public.products product ON product.company_id=relation.company_id
    AND product.id=relation.product_id
  JOIN public.suppliers supplier ON supplier.company_id=relation.company_id
    AND supplier.id=relation.supplier_id
  JOIN public.product_uoms product_uom
    ON product_uom.company_id=relation.company_id
   AND product_uom.product_id=relation.product_id
   AND product_uom.uom_id=relation.purchase_uom_id
  WHERE relation.is_active AND (
    NOT product.is_active OR product.is_bundle OR NOT supplier.is_active
    OR NOT product_uom.is_active OR NOT product_uom.purchase_allowed)

  UNION ALL
  SELECT 'invalid_product_supplier_value',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.product_suppliers relation
  WHERE relation.reference_purchase_price<0
     OR relation.last_purchase_price<0
     OR (relation.is_preferred_supplier AND NOT relation.is_active)
     OR (relation.last_purchase_price IS NOT NULL
       AND relation.last_price_updated_at IS NULL)

  UNION ALL
  SELECT 'multiple_active_preferred_supplier',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('product_count',count(*))
  FROM (
    SELECT company_id,product_id FROM public.product_suppliers
    WHERE is_active AND is_preferred_supplier
    GROUP BY company_id,product_id HAVING count(*)>1
  ) duplicate_preferred

  UNION ALL
  SELECT 'duplicate_normalized_supplier_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicate_groups',count(*))
  FROM (
    SELECT supplier.company_id,'CODE' identity_type,
      upper(regexp_replace(btrim(supplier.supplier_code),'\s+',' ','g')) identity_value
    FROM public.suppliers supplier GROUP BY supplier.company_id,
      upper(regexp_replace(btrim(supplier.supplier_code),'\s+',' ','g'))
    HAVING count(*)>1
    UNION ALL
    SELECT supplier.company_id,'NAME',
      lower(regexp_replace(btrim(supplier.supplier_name),'\s+',' ','g'))
    FROM public.suppliers supplier GROUP BY supplier.company_id,
      lower(regexp_replace(btrim(supplier.supplier_name),'\s+',' ','g'))
    HAVING count(*)>1
  ) duplicate_group

  UNION ALL
  SELECT 'supplier_operational_document_reference_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('orphan_or_cross_tenant_rows',count(*))
  FROM (
    SELECT document.company_id,document.supplier_id
    FROM public.supplier_order_documents document
    UNION ALL
    SELECT receipt.company_id,supplier_order.supplier_id
    FROM public.goods_receipt_documents receipt
    JOIN public.supplier_order_documents supplier_order
      ON supplier_order.company_id=receipt.company_id
     AND supplier_order.id=receipt.supplier_order_id
    UNION ALL
    SELECT document.company_id,document.supplier_id
    FROM public.purchase_return_documents document
    UNION ALL
    SELECT document.company_id,document.supplier_id
    FROM public.supplier_invoice_documents document
    UNION ALL
    SELECT document.company_id,document.supplier_id
    FROM public.supplier_payment_documents document
  ) reference
  LEFT JOIN public.suppliers supplier ON supplier.company_id=reference.company_id
    AND supplier.id=reference.supplier_id
  WHERE supplier.id IS NULL

  UNION ALL
  SELECT 'supplier_nonterminal_import_jobs',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('job_count',count(*),'companies',count(DISTINCT company_id))
  FROM public.master_import_jobs
  WHERE import_type IN('SUPPLIER','PRODUCT_SUPPLIER')
    AND status NOT IN('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED')

  UNION ALL
  SELECT 'supplier_runtime_inventory','INFO',jsonb_build_object(
    'companies',count(DISTINCT supplier.company_id),'suppliers',count(DISTINCT supplier.id),
    'active_suppliers',count(DISTINCT supplier.id) FILTER(WHERE supplier.is_active),
    'product_supplier_rows',count(relation.id),
    'active_product_supplier_rows',count(relation.id) FILTER(WHERE relation.is_active),
    'preferred_product_supplier_rows',count(relation.id) FILTER(
      WHERE relation.is_active AND relation.is_preferred_supplier),
    'suppliers_with_bank_reference',count(DISTINCT supplier.id) FILTER(
      WHERE supplier.bank_account_number IS NOT NULL))
  FROM public.suppliers supplier
  LEFT JOIN public.product_suppliers relation
    ON relation.company_id=supplier.company_id AND relation.supplier_id=supplier.id
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2
  WHEN 'SETUP' THEN 3 WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
