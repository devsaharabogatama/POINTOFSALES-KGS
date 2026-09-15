-- Backoffice Quotation/Sales Order runtime preflight. READ ONLY.
WITH results AS (
  SELECT
    'backoffice_order_foundation_dependency'::text AS check_name,
    CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END::text AS status,
    jsonb_build_object('ledgerRows',count(*)) AS details
  FROM private.kgs_schema_migrations
  WHERE version = '20260908110000'

  UNION ALL

  SELECT
    'backoffice_sales_feature_default_off',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('enabledCompanies',count(*))
  FROM public.company_features
  WHERE feature_code = 'backoffice_delivered_qty_sales_enabled'
    AND is_enabled

  UNION ALL

  SELECT
    'backoffice_order_runtime_object_collision',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('existingObjects',COALESCE(jsonb_agg(object_name),'[]'::jsonb))
  FROM (
    SELECT object_name
    FROM (VALUES
      ('sales.backoffice_orders'),
      ('public.get_backoffice_sales_order_workspace()'),
      ('public.get_backoffice_sales_orders(text,text,integer)'),
      ('public.get_backoffice_sales_order(uuid)'),
      ('public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)'),
      ('public.send_backoffice_sales_quotation(uuid,bigint,uuid)'),
      ('public.confirm_backoffice_sales_order(uuid,bigint,uuid)'),
      ('public.cancel_backoffice_sales_order(uuid,bigint,uuid,text)')
    ) expected(object_name)
    WHERE CASE
      WHEN object_name LIKE 'sales.%' THEN EXISTS(
        SELECT 1 FROM public.access_permission_catalog
        WHERE permission_key = object_name
      )
      ELSE to_regprocedure(object_name) IS NOT NULL
    END
  ) collisions

  UNION ALL

  SELECT
    'backoffice_order_foundation_zero_rows',
    CASE WHEN total_rows = 0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',total_rows)
  FROM (
    SELECT
      (SELECT count(*) FROM public.backoffice_sales_orders)
      + (SELECT count(*) FROM public.backoffice_sales_order_lines)
      + (SELECT count(*) FROM public.backoffice_sales_order_operations)
      + (SELECT count(*) FROM public.backoffice_sales_order_audit) AS total_rows
  ) inventory

  UNION ALL

  SELECT
    'active_finance_posting_queue',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN ('PREVIEWED','APPROVED','PROCESSING')

  UNION ALL

  SELECT
    'nonterminal_offline_submission',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN ('QUEUED','SYNCING','NEEDS_CONFIRMATION')

  UNION ALL

  SELECT
    'runtime_security_dependencies',
    CASE WHEN count(*) = 4 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',4,'routineRows',count(*))
  FROM (VALUES
    ('public.private_active_company_id()'),
    ('public.private_request_company_matches(uuid)'),
    ('private.acp_require_permission_capability(uuid,text,text)'),
    ('private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamp with time zone)')
  ) required(signature)
  WHERE to_regprocedure(signature) IS NOT NULL

  UNION ALL

  SELECT
    'backoffice_order_permission_role_scope',
    'REVIEW',
    jsonb_build_object(
      'proposedViewRoles',ARRAY[
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','FINANCE','ACCOUNTING'
      ],
      'proposedOperatorRoles',ARRAY[
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'
      ],
      'requiredFeature','backoffice_delivered_qty_sales_enabled',
      'rule','Feature OFF yields no effective capability, including Super Admin'
    )

  UNION ALL

  SELECT
    'backoffice_order_fixture_inventory',
    'INFO',
    jsonb_build_object(
      'activeCompanies',(SELECT count(*) FROM public.companies WHERE status='ACTIVE'),
      'activeStores',(SELECT count(*) FROM public.stores WHERE status='ACTIVE'),
      'activeWarehouses',(SELECT count(*) FROM public.warehouses WHERE is_active),
      'activeCustomers',(SELECT count(*) FROM public.customers WHERE is_active),
      'activeSalesProductUoms',(SELECT count(*) FROM public.product_uoms
        WHERE is_active AND sales_allowed)
    )
)
SELECT check_name,status,details
FROM results
ORDER BY CASE status
  WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2 WHEN 'PASS' THEN 3 ELSE 4 END,
  check_name;
