-- ACP-5G preflight: Bundle management and independent POS component runtime.
-- SAFETY: one SELECT statement; aggregate metadata only; no business identity.

WITH required_versions(version) AS (
  VALUES ('20260729010000'),('20260729070000'),('20260812150000'),
    ('20260813030000')
), expected_relations(relation_name) AS (
  VALUES ('product_bundle_items'),('product_bundle_master_audit'),
    ('bundle_sale_allocations'),('sale_fifo_allocations')
), bundle_routines AS (
  SELECT procedure.oid,procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure
  WHERE procedure.oid IN (
    to_regprocedure(
      'public.save_bundle_with_components(uuid,bigint,text,text,uuid,uuid,numeric,text,text,boolean,jsonb)'),
    to_regprocedure('public.get_bundle_availability(uuid,uuid)')
  )
), checks AS (
  SELECT 'acp_phase5g_dependencies'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE ledger.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(required.version ORDER BY required.version)
        FILTER(WHERE ledger.version IS NULL),'[]'::JSONB)) details
  FROM required_versions required
  LEFT JOIN private.kgs_schema_migrations ledger
    ON ledger.version=required.version

  UNION ALL
  SELECT 'bundle_permission_catalog_state',
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE
      enforcement_status='SHADOW' AND is_customizable
      AND view_roles=ARRAY[
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','FINANCE','ACCOUNTING'
      ]::TEXT[]
      AND operator_roles=ARRAY[
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'
      ]::TEXT[]
      AND supported_capabilities @> ARRAY['VIEW','MANAGE']::TEXT[]
      AND cardinality(supported_capabilities)=2
    )=1 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB),'capabilities',COALESCE(
        (SELECT to_jsonb(supported_capabilities)
         FROM public.access_permission_catalog
         WHERE permission_key='sales.bundles'),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='sales.bundles'

  UNION ALL
  SELECT 'canonical_bundle_schema_state',
    CASE WHEN count(*) FILTER(WHERE relation.oid IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(expected.relation_name ORDER BY expected.relation_name)
        FILTER(WHERE relation.oid IS NULL),'[]'::JSONB))
  FROM expected_relations expected
  LEFT JOIN pg_class relation ON relation.relname=expected.relation_name
    AND relation.relnamespace='public'::regnamespace

  UNION ALL
  SELECT 'canonical_bundle_composed_read_state','SETUP',
    jsonb_build_object('rpc_exists',to_regprocedure(
      'public.get_sales_bundles()') IS NOT NULL,
      'required_design',jsonb_build_array(
        'guard Backoffice list/detail with sales.bundles VIEW',
        'return Bundle, composition, sales UOM and narrow Product/UOM labels',
        'do not expose full Product, Stock, FIFO, Sale or Finance ledgers'))

  UNION ALL
  SELECT 'bundle_direct_read_cutover_scope','REVIEW',
    jsonb_build_object('authenticated_read_relations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE readable),
      '[]'::JSONB),'required_design',jsonb_build_array(
        'replace Bundle management table reads with one VIEW-guarded RPC',
        'keep Product and UOM references narrow and Bundle-authorized',
        'revoke dedicated Bundle table SELECT only after all consumers migrate',
        'do not revoke shared Product, UOM, Sale allocation or FIFO reads here'))
  FROM (
    SELECT expected.relation_name,has_table_privilege(
      'authenticated',format('public.%I',expected.relation_name),'SELECT') readable
    FROM expected_relations expected
    WHERE expected.relation_name IN (
      'product_bundle_items','product_bundle_master_audit')
  ) privilege_state

  UNION ALL
  SELECT 'bundle_authority_split','REVIEW',
    jsonb_build_object(
      'management_roles',jsonb_build_array(
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'),
      'view_only_roles',jsonb_build_array('FINANCE','ACCOUNTING'),
      'required_design',jsonb_build_array(
        'Bundle identity, sales UOM and composition mutate atomically under MANAGE',
        'Product master keeps STOCK Product management under inventory.products',
        'availability VIEW does not grant Stock Real or Stock Movement access',
        'Bundle has no physical stock, FIFO batch or movement of its own'))

  UNION ALL
  SELECT 'bundle_pos_consumer_scope','REVIEW',
    jsonb_build_object('required_design',jsonb_build_array(
      'POS eligibility requires its own active Cashier session and Store scope',
      'server expands Bundle components and resolves authoritative quantity',
      'posting consumes component FIFO and never physical Bundle stock',
      'Backoffice restriction must not widen or break online POS authority'))

  UNION ALL
  SELECT 'bundle_sales_return_consumer_scope','REVIEW',
    jsonb_build_object('required_design',jsonb_build_array(
      'Sales Return uses immutable Bundle sale allocation snapshots',
      'Return authority never inherits sales.bundles MANAGE',
      'historical allocation remains readable only through its owning workflow'))

  UNION ALL
  SELECT 'bundle_import_export_contract','REVIEW',
    jsonb_build_object('required_design',jsonb_build_array(
      'Bundle remains excluded from generic Product import',
      'no Bundle IMPORT or EXPORT capability is opened by ACP-5G',
      'future Bundle exchange requires an explicit grouped composition contract'))

  UNION ALL
  SELECT 'bundle_runtime_permission_hook_state','SETUP',
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'
        AND definition ILIKE '%sales.bundles%'),
      'routine_names',COALESCE(jsonb_agg(proname ORDER BY proname),
        '[]'::JSONB))
  FROM bundle_routines

  UNION ALL
  SELECT 'bundle_mutation_and_availability_routine_state',
    CASE WHEN count(DISTINCT proname)=2
      AND count(*) FILTER(WHERE has_function_privilege(
        'authenticated',oid,'EXECUTE'))=2
      AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routine_rows',count(*),
      'routine_names',COALESCE(jsonb_agg(DISTINCT proname ORDER BY proname),
        '[]'::JSONB),'authenticated_executable_rows',count(*) FILTER(WHERE
        has_function_privilege('authenticated',oid,'EXECUTE')),
      'anon_executable_rows',count(*) FILTER(WHERE
        has_function_privilege('anon',oid,'EXECUTE')))
  FROM bundle_routines

  UNION ALL
  SELECT 'bundle_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE writable)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('direct_write_relations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE writable),
      '[]'::JSONB))
  FROM (
    SELECT relation_name,has_table_privilege(
      'authenticated',format('public.%I',relation_name),
      'INSERT,UPDATE,DELETE') writable
    FROM (VALUES ('products'),('product_uoms'),('product_bundle_items'),
      ('product_bundle_master_audit')) relation(relation_name)
  ) write_state

  UNION ALL
  SELECT 'bundle_override_tenant_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.user_company_permission_overrides override_row
  LEFT JOIN public.company_memberships membership
    ON membership.company_id=override_row.company_id
   AND membership.user_id=override_row.user_id
  WHERE override_row.permission_key='sales.bundles'
    AND membership.user_id IS NULL

  UNION ALL
  SELECT 'active_bundle_without_component',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('bundle_count',count(*))
  FROM public.products bundle
  WHERE bundle.is_active AND bundle.is_bundle AND NOT EXISTS (
    SELECT 1 FROM public.product_bundle_items item
    WHERE item.company_id=bundle.company_id AND item.bundle_id=bundle.id)

  UNION ALL
  SELECT 'invalid_bundle_sales_uom_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('bundle_count',count(*))
  FROM (
    SELECT bundle.company_id,bundle.id,
      count(product_uom.id) FILTER(WHERE product_uom.is_active
        AND product_uom.sales_allowed AND NOT product_uom.purchase_allowed
        AND product_uom.factor_to_base=1) valid_sales_uom,
      count(product_uom.id) FILTER(WHERE product_uom.is_active
        AND product_uom.purchase_allowed) purchase_uom
    FROM public.products bundle
    LEFT JOIN public.product_uoms product_uom
      ON product_uom.company_id=bundle.company_id
     AND product_uom.product_id=bundle.id
    WHERE bundle.is_active AND bundle.is_bundle
    GROUP BY bundle.company_id,bundle.id
  ) bundle_uom
  WHERE valid_sales_uom<>1 OR purchase_uom<>0

  UNION ALL
  SELECT 'invalid_bundle_component_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.product_bundle_items item
  LEFT JOIN public.products bundle
    ON bundle.company_id=item.company_id AND bundle.id=item.bundle_id
  LEFT JOIN public.products component
    ON component.company_id=item.company_id AND component.id=item.item_id
  LEFT JOIN public.product_uoms product_uom
    ON product_uom.company_id=item.company_id
   AND product_uom.product_id=item.item_id
   AND product_uom.uom_id=item.component_uom_id
  WHERE bundle.id IS NULL OR NOT bundle.is_bundle
     OR component.id IS NULL OR component.is_bundle OR NOT component.is_active
     OR product_uom.id IS NULL OR NOT product_uom.is_active
     OR item.bundle_id=item.item_id OR item.component_qty<=0

  UNION ALL
  SELECT 'duplicate_bundle_component',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicate_groups',count(*))
  FROM (
    SELECT company_id,bundle_id,item_id,component_uom_id
    FROM public.product_bundle_items
    GROUP BY company_id,bundle_id,item_id,component_uom_id
    HAVING count(*)>1
  ) duplicate_group

  UNION ALL
  SELECT 'bundle_with_physical_stock_or_fifo',
    CASE WHEN sum(row_count)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object(
      'stock_rows',sum(row_count) FILTER(WHERE source='stock'),
      'movement_rows',sum(row_count) FILTER(WHERE source='movement'),
      'fifo_rows',sum(row_count) FILTER(WHERE source='fifo'))
  FROM (
    SELECT 'stock' source,count(*) row_count
    FROM public.product_stocks stock
    JOIN public.products bundle ON bundle.company_id=stock.company_id
      AND bundle.id=stock.product_id AND bundle.is_bundle
    UNION ALL
    SELECT 'movement',count(*) FROM public.stock_movements movement
    JOIN public.products bundle ON bundle.company_id=movement.company_id
      AND bundle.id=movement.product_id AND bundle.is_bundle
    UNION ALL
    SELECT 'fifo',count(*) FROM public.product_batches batch
    JOIN public.products bundle ON bundle.company_id=batch.company_id
      AND bundle.id=batch.product_id AND bundle.is_bundle
  ) physical_state

  UNION ALL
  SELECT 'posted_bundle_requirement_allocation_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('requirement_count',count(*))
  FROM public.sale_stock_requirements requirement
  JOIN public.sales_headers sale ON sale.company_id=requirement.company_id
    AND sale.id=requirement.sales_id AND sale.document_status='POSTED'
  JOIN public.products bundle ON bundle.company_id=requirement.company_id
    AND bundle.id=requirement.commercial_product_id AND bundle.is_bundle
  LEFT JOIN public.bundle_sale_allocations allocation
    ON allocation.company_id=requirement.company_id
   AND allocation.stock_requirement_id=requirement.id
  WHERE allocation.id IS NULL

  UNION ALL
  SELECT 'invalid_bundle_sale_allocation_reference',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.bundle_sale_allocations allocation
  LEFT JOIN public.products bundle ON bundle.company_id=allocation.company_id
    AND bundle.id=allocation.bundle_product_id
  LEFT JOIN public.products component
    ON component.company_id=allocation.company_id
   AND component.id=allocation.component_product_id
  WHERE bundle.id IS NULL OR NOT bundle.is_bundle
     OR component.id IS NULL OR component.is_bundle

  UNION ALL
  SELECT 'bundle_runtime_inventory','INFO',
    jsonb_build_object(
      'companies',(SELECT count(DISTINCT company_id) FROM public.products
        WHERE is_bundle),
      'bundles',(SELECT count(*) FROM public.products WHERE is_bundle),
      'active_bundles',(SELECT count(*) FROM public.products
        WHERE is_bundle AND is_active),
      'component_rows',(SELECT count(*) FROM public.product_bundle_items),
      'bundle_sale_allocations',(SELECT count(*)
        FROM public.bundle_sale_allocations),
      'bundle_fifo_allocations',(SELECT count(*)
        FROM public.sale_fifo_allocations
        WHERE bundle_sale_allocation_id IS NOT NULL),
      'override_rows',(SELECT count(*)
        FROM public.user_company_permission_overrides
        WHERE permission_key='sales.bundles'))
)
SELECT check_name,status,details
FROM checks
ORDER BY CASE status
  WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2 WHEN 'SETUP' THEN 3
  WHEN 'BACKFILL' THEN 4 WHEN 'PASS' THEN 5 ELSE 6 END,check_name;
