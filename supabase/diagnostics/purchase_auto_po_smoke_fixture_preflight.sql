-- SELECT-only preflight for the persistent AUTO_PO smoke fixture.
WITH constants AS (
  SELECT
    'd290f1ee-6c54-4b01-90e6-d701748f0851'::uuid company_id,
    '08fc496d-af34-4d7e-8aad-4afe3762f1e0'::uuid actor_id,
    '52bb8c83-32e9-4083-bbd5-da1478427c09'::uuid existing_product_id,
    'cf6fcf35-bf2f-4f00-934e-1c211cf7aa45'::uuid source_warehouse_id,
    '6ba40fc1-48bf-4302-bf8d-d71432a34ff2'::uuid receiving_warehouse_id
), company_day AS (
  SELECT (clock_timestamp() AT TIME ZONE company.timezone)::date business_date
  FROM constants JOIN public.companies company ON company.id=constants.company_id
), checks AS (
  SELECT 'fixture_environment_identity' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(1-count(*))::bigint violation_rows,
    jsonb_build_object('expected','KGS Company + localadmin@local.com','rows',count(*)) details
  FROM constants
  JOIN public.companies company ON company.id=constants.company_id
    AND company.company_code='KGS' AND company.company_name='KGS Company'
    AND company.status='ACTIVE'
  JOIN public.profiles profile ON profile.id=constants.actor_id
    AND profile.email='localadmin@local.com' AND profile.role='super_admin'
  JOIN public.user_active_company_contexts context ON context.user_id=constants.actor_id
    AND context.company_id=constants.company_id
  UNION ALL
  SELECT 'fixture_single_active_company_scope',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(1-count(*))::bigint,
    jsonb_build_object('activeCompanies',count(*),'required',1)
  FROM public.companies WHERE status='ACTIVE'
  UNION ALL
  SELECT 'fixture_required_migration_chain',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(3-count(*))::bigint,
    jsonb_build_object('present',count(*),'expected',3)
  FROM private.kgs_schema_migrations
  WHERE version IN('20260914141000','20260914150000','20260914160000')
  UNION ALL
  SELECT 'fixture_purchase_setting',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(1-count(*))::bigint,
    jsonb_build_object('requiredModeBeforeFixture','AUTO_RO',
      'requiredReceivingWarehouseId',(SELECT receiving_warehouse_id FROM constants),
      'matchingRows',count(*))
  FROM constants
  JOIN public.company_purchase_replenishment_settings setting
    ON setting.company_id=constants.company_id
   AND setting.replenishment_mode='AUTO_RO'
   AND setting.default_purchase_receipt_warehouse_id=constants.receiving_warehouse_id
   AND setting.updated_by=constants.actor_id
  UNION ALL
  SELECT 'fixture_canonical_masters',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(3-count(*))::bigint,
    jsonb_build_object('present',count(*),'expected',3)
  FROM constants
  CROSS JOIN LATERAL (VALUES
    (EXISTS(SELECT 1 FROM public.products product
      WHERE product.company_id=constants.company_id
        AND product.id=constants.existing_product_id AND product.is_active)),
    (EXISTS(SELECT 1 FROM public.warehouses warehouse
      WHERE warehouse.company_id=constants.company_id
        AND warehouse.id=constants.source_warehouse_id AND warehouse.is_active)),
    (EXISTS(SELECT 1 FROM public.warehouses warehouse
      WHERE warehouse.company_id=constants.company_id
        AND warehouse.id=constants.receiving_warehouse_id
        AND warehouse.is_active AND warehouse.is_purchase_destination
        AND warehouse.warehouse_type<>'TRANSIT'))
  ) fact(present)
  WHERE fact.present
  UNION ALL
  SELECT 'fixture_negative_stock_shape',
    CASE WHEN count(stock.product_id)=1 AND bool_and(stock.product_id=constants.existing_product_id
      AND stock.warehouse_id=constants.source_warehouse_id AND stock.stock_qty=-102)
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(stock.product_id)=1 AND bool_and(stock.product_id=constants.existing_product_id
      AND stock.warehouse_id=constants.source_warehouse_id AND stock.stock_qty=-102)
      THEN 0 ELSE greatest(count(stock.product_id),1) END::bigint,
    jsonb_build_object('negativeRows',count(stock.product_id),'requiredExistingQty',-102)
  FROM constants
  LEFT JOIN public.product_stocks stock ON stock.company_id=constants.company_id
    AND stock.stock_qty<0
  GROUP BY constants.existing_product_id,constants.source_warehouse_id
  UNION ALL
  SELECT 'fixture_open_purchase_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('openSupplierOrders',count(*))
  FROM constants JOIN public.supplier_order_documents document
    ON document.company_id=constants.company_id
   AND document.status IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED')
  UNION ALL
  SELECT 'fixture_today_scheduler_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('existingTodayBatchOrRun',count(*))
  FROM constants CROSS JOIN company_day
  CROSS JOIN LATERAL (
    SELECT batch.id FROM public.purchase_daily_batches batch
    WHERE batch.company_id=constants.company_id
      AND batch.business_date=company_day.business_date
    UNION ALL
    SELECT run.id FROM public.purchase_daily_scheduler_runs run
    WHERE run.company_id=constants.company_id
      AND run.business_date=company_day.business_date
  ) existing
  UNION ALL
  SELECT 'fixture_identity_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('existingFixtureMasters',count(*))
  FROM constants CROSS JOIN LATERAL (
    SELECT product.id FROM public.products product
    WHERE product.company_id=constants.company_id
      AND product.sku LIKE 'AUTOPO-SMOKE-%'
    UNION ALL
    SELECT supplier.id FROM public.suppliers supplier
    WHERE supplier.company_id=constants.company_id
      AND supplier.supplier_code LIKE 'AUTOPO-SMOKE-%'
  ) fixture
  UNION ALL
  SELECT 'fixture_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('activeRuns',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 ELSE 1 END,check_name;
