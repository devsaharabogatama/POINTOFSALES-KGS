-- Purchase Daily Replenishment Step 4/6: SELECT-only preflight.
-- Run the complete file on isolated Development only.
WITH required_versions(version) AS (VALUES
  ('20260913100000'::text),('20260913110000'),('20260913120000')
), new_routines(signature) AS (VALUES
  ('private.get_purchase_daily_automatic_candidates_core(uuid,date)'::text),
  ('private.generate_purchase_daily_auto_po_core(uuid,date,uuid,uuid,timestamptz)'),
  ('public.generate_purchase_daily_auto_po(date,uuid)')
), dependencies(signature) AS (VALUES
  ('private.get_purchase_daily_auto_ro_candidates_core(uuid,date)'::text),
  ('private.purchase_daily_batch_snapshot(uuid,uuid)'),
  ('public.private_active_company_id()'),
  ('private.acp_require_permission_capability(uuid,text,text)')
), checks AS (
  SELECT 'pdr4_dependency_ledger'::text check_name,
    CASE WHEN count(ledger.version)=3 THEN 'PASS' ELSE 'BLOCKER' END status,
    (3-count(ledger.version))::bigint violation_rows,
    jsonb_build_object('expected',3,'present',count(ledger.version),
      'missing',COALESCE(jsonb_agg(required.version)
        FILTER(WHERE ledger.version IS NULL),'[]'::jsonb)) details
  FROM required_versions required LEFT JOIN private.kgs_schema_migrations ledger USING(version)
  UNION ALL
  SELECT 'pdr4_runtime_dependency_contract',
    CASE WHEN count(to_regprocedure(signature))=4 THEN 'PASS' ELSE 'BLOCKER' END,
    (4-count(to_regprocedure(signature)))::bigint,
    jsonb_build_object('expected',4,'present',count(to_regprocedure(signature)),
      'missing',COALESCE(jsonb_agg(signature)
        FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'::jsonb))
  FROM dependencies
  UNION ALL
  SELECT 'pdr4_routine_collision',
    CASE WHEN count(to_regprocedure(signature))=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(to_regprocedure(signature))::bigint,
    jsonb_build_object('existing',COALESCE(jsonb_agg(signature)
      FILTER(WHERE to_regprocedure(signature) IS NOT NULL),'[]'::jsonb))
  FROM new_routines
  UNION ALL
  SELECT 'pdr4_operation_constraint_contract',
    CASE WHEN count(*)=1 AND bool_and(position('GENERATE_AUTO_RO' in pg_get_constraintdef(oid))>0
        AND position('CONFIRM_AUTO_RO' in pg_get_constraintdef(oid))>0
        AND position('GENERATE_AUTO_PO' in pg_get_constraintdef(oid))=0)
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)=1 AND bool_and(position('GENERATE_AUTO_RO' in pg_get_constraintdef(oid))>0
        AND position('CONFIRM_AUTO_RO' in pg_get_constraintdef(oid))>0
        AND position('GENERATE_AUTO_PO' in pg_get_constraintdef(oid))=0)
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('constraintRows',count(*),'step4AlreadyPresent',COALESCE(bool_or(
      position('GENERATE_AUTO_PO' in pg_get_constraintdef(oid))>0),false))
  FROM pg_constraint WHERE conrelid='public.purchase_daily_batch_operations'::regclass
    AND conname='purchase_daily_batch_operations_operation_type_check'
  UNION ALL
  SELECT 'pdr4_audit_constraint_contract',
    CASE WHEN count(*)=1 AND bool_and(position('GENERATE' in pg_get_constraintdef(oid))>0
        AND position('REUSE' in pg_get_constraintdef(oid))>0
        AND position('CONFIRM' in pg_get_constraintdef(oid))>0
        AND position('AUTO_PO_GENERATE' in pg_get_constraintdef(oid))=0)
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)=1 AND bool_and(position('GENERATE' in pg_get_constraintdef(oid))>0
        AND position('REUSE' in pg_get_constraintdef(oid))>0
        AND position('CONFIRM' in pg_get_constraintdef(oid))>0
        AND position('AUTO_PO_GENERATE' in pg_get_constraintdef(oid))=0)
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('constraintRows',count(*),'step4AlreadyPresent',COALESCE(bool_or(
      position('AUTO_PO_GENERATE' in pg_get_constraintdef(oid))>0),false))
  FROM pg_constraint WHERE conrelid='public.purchase_daily_batch_audit'::regclass
    AND conname='purchase_daily_batch_audit_action_check'
  UNION ALL
  SELECT 'pdr4_line_readiness_constraint_contract',
    CASE WHEN count(*)=1 AND bool_and(position('READY' in pg_get_constraintdef(oid))>0
        AND position('ORDERED' in pg_get_constraintdef(oid))>0
        AND position('PURCHASE_UOM_QUANTITY_NOT_EXACT' in pg_get_constraintdef(oid))=0
        AND position('PRODUCT_UOM_SETUP_REQUIRED' in pg_get_constraintdef(oid))=0)
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)=1 AND bool_and(position('READY' in pg_get_constraintdef(oid))>0
        AND position('ORDERED' in pg_get_constraintdef(oid))>0
        AND position('PURCHASE_UOM_QUANTITY_NOT_EXACT' in pg_get_constraintdef(oid))=0
        AND position('PRODUCT_UOM_SETUP_REQUIRED' in pg_get_constraintdef(oid))=0)
      THEN 0 ELSE 1 END::bigint,jsonb_build_object('constraintRows',count(*))
  FROM pg_constraint WHERE conrelid='public.purchase_daily_batch_lines'::regclass
    AND conname='purchase_daily_batch_line_readiness_check'
  UNION ALL
  SELECT 'pdr4_existing_auto_po_batch',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('rows',count(*),
      'rule','AUTO_PO runtime did not exist before Step 4')
  FROM public.purchase_daily_batches WHERE mode_snapshot='AUTO_PO'
  UNION ALL
  SELECT 'pdr4_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'pdr4_nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'pdr4_open_cutover_plan',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('openPlans',count(*))
  FROM public.sales_process_cutover_plans WHERE status IN('DRAFT','PREVIEWED','APPLYING')
  UNION ALL
  SELECT 'pdr4_runtime_inventory','INFO',0::bigint,jsonb_build_object(
    'autoPoCompanies',(SELECT count(*) FROM public.company_purchase_replenishment_settings
      WHERE replenishment_mode='AUTO_PO'),
    'negativeOnHandRows',(SELECT count(*) FROM public.product_stocks WHERE stock_qty<0),
    'warehouseSetupRequired',(SELECT count(*) FROM public.product_stocks stock
      JOIN public.products product ON product.company_id=stock.company_id AND product.id=stock.product_id
      JOIN public.warehouses warehouse ON warehouse.company_id=stock.company_id
        AND warehouse.id=stock.warehouse_id
      JOIN public.company_purchase_replenishment_settings setting ON setting.company_id=stock.company_id
      WHERE stock.stock_qty<0 AND NOT (warehouse.is_active AND warehouse.is_purchase_destination
        AND warehouse.warehouse_type IS DISTINCT FROM 'TRANSIT')
        AND setting.default_purchase_receipt_warehouse_id IS NULL),
    'requiredProjectRef','fkywtxucmyjvpwdiqpix')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
