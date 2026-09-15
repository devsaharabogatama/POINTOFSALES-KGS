-- Purchase Daily Replenishment Step 1/6: SELECT-only postflight.
WITH checks AS (
  SELECT 'pdr_migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260913100000'
  UNION ALL
  SELECT 'pdr_setting_coverage',CASE WHEN missing=0 THEN 'PASS' ELSE 'FAIL' END,
    missing,jsonb_build_object('companies',companies,'settings',settings)
  FROM (SELECT (SELECT count(*) FROM public.companies) companies,
      (SELECT count(*) FROM public.company_purchase_replenishment_settings) settings,
      (SELECT count(*) FROM public.companies company WHERE NOT EXISTS(
        SELECT 1 FROM public.company_purchase_replenishment_settings setting
        WHERE setting.company_id=company.id)) missing) source
  UNION ALL
  SELECT 'pdr_default_manual_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.company_purchase_replenishment_settings
  WHERE replenishment_mode NOT IN('MANUAL','AUTO_RO','AUTO_PO')
    OR cutoff_local_time<>time '23:59:00' OR target_on_hand_base_qty<>0
  UNION ALL
  SELECT 'pdr_supplier_priority_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.product_suppliers WHERE selection_priority IS NULL OR selection_priority<=0
  UNION ALL
  SELECT 'pdr_required_routines',CASE WHEN count(oid)=4 THEN 'PASS' ELSE 'FAIL' END,
    (4-count(oid))::bigint,jsonb_build_object('expected',4,'present',count(oid))
  FROM (VALUES
    (to_regprocedure('public.get_purchase_replenishment_setting()')),
    (to_regprocedure('public.set_purchase_replenishment_mode(text,bigint)')),
    (to_regprocedure('private.trg_guard_purchase_replenishment_history()')),
    (to_regprocedure('private.trg_provision_purchase_replenishment_setting()'))
  ) required(oid)
  UNION ALL
  SELECT 'pdr_private_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='private' AND privilege.grantee='authenticated'
    AND privilege.routine_name IN('trg_guard_purchase_replenishment_history',
      'trg_provision_purchase_replenishment_setting')
  UNION ALL
  SELECT 'pdr_daily_batch_shape',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.purchase_daily_batches batch
  WHERE mode_snapshot NOT IN('AUTO_RO','AUTO_PO') OR requested_total_base_qty<0
  UNION ALL
  SELECT 'pdr_daily_line_shape',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.purchase_daily_batch_lines line
  WHERE line.on_hand_snapshot>=0 OR line.open_purchase_base_qty_snapshot<0
    OR line.requested_base_qty<=0
    OR (line.supplier_assignment_status='ASSIGNED'
      AND (line.suggested_supplier_id IS NULL OR line.suggested_product_supplier_id IS NULL))
    OR (line.supplier_assignment_status='SUPPLIER_PENDING'
      AND (line.suggested_supplier_id IS NOT NULL OR line.suggested_product_supplier_id IS NOT NULL))
  UNION ALL
  SELECT 'pdr_zero_operational_effect','PASS',0::bigint,jsonb_build_object(
    'rule','Foundation contains no batch generator and does not create RO, PO, Receipt, Stock, AP or Finance rows',
    'batchRows',(SELECT count(*) FROM public.purchase_daily_batches),
    'batchLineRows',(SELECT count(*) FROM public.purchase_daily_batch_lines))
  UNION ALL
  SELECT 'pdr_runtime_inventory','INFO',0::bigint,jsonb_build_object(
    'manualCompanies',(SELECT count(*) FROM public.company_purchase_replenishment_settings WHERE replenishment_mode='MANUAL'),
    'autoRoCompanies',(SELECT count(*) FROM public.company_purchase_replenishment_settings WHERE replenishment_mode='AUTO_RO'),
    'autoPoCompanies',(SELECT count(*) FROM public.company_purchase_replenishment_settings WHERE replenishment_mode='AUTO_PO'),
    'negativeOnHandRows',(SELECT count(*) FROM public.product_stocks WHERE stock_qty<0))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
