-- SELECT-only postflight for Step 4/6.5C2C. Run the entire file.
WITH routine AS (
  SELECT n.nspname,p.proname,p.prosecdef,p.provolatile,p.proconfig,pg_get_functiondef(p.oid) definition
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE (n.nspname,p.proname) IN(('private','backoffice_sales_invoice_ui_snapshot'),
    ('public','get_backoffice_sales_invoice_workspace'))
), checks AS (
  SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260912125000'
  UNION ALL
  SELECT 'c2c_required_read_routines',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(2-count(*)),jsonb_build_object('expected',2,'present',count(*)) FROM routine
  UNION ALL
  SELECT 'c2c_read_model_definition',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    2-count(*),jsonb_build_object('matched',count(*)) FROM routine
  WHERE (nspname='private' AND position('''sourceKind''' in definition)>0
      AND position('discrepancy.accepted_overage_base_qty' in definition)>0)
     OR (nspname='public' AND position('''acceptedOverageLines''' in definition)>0
      AND position('overage_to_invoice_base_qty' in definition)>0)
  UNION ALL
  SELECT 'c2c_security_contract',CASE WHEN bool_and(prosecdef AND proconfig @> ARRAY['search_path=public, pg_temp']) THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE NOT prosecdef OR NOT(proconfig @> ARRAY['search_path=public, pg_temp'])),
    jsonb_build_object('routineRows',count(*)) FROM routine
  UNION ALL
  SELECT 'c2c_private_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges WHERE routine_schema='private'
    AND routine_name='backoffice_sales_invoice_ui_snapshot' AND grantee='authenticated' AND privilege_type='EXECUTE'
  UNION ALL
  SELECT 'c2c_source_counter_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_delivery_discrepancy_lines
  WHERE draft_overage_invoice_allocated_base_qty<0 OR invoiced_overage_base_qty<0
    OR overage_to_invoice_base_qty<0
  UNION ALL
  SELECT 'c2c_runtime_inventory','INFO',0,jsonb_build_object(
    'resolvedSources',count(*),'remainingSources',count(*) FILTER(WHERE overage_to_invoice_base_qty>0))
  FROM public.backoffice_sales_delivery_discrepancy_lines
  WHERE requested_resolution='ACCEPT_OVERAGE' AND commercial_approval_status='APPROVED'
    AND warehouse_resolution_status='RESOLVED'
)
SELECT * FROM checks ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
