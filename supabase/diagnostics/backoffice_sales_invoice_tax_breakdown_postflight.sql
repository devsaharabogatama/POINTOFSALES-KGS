-- Read-only postflight for 20260909159000.
WITH checks AS (
  SELECT 'migration_ledger'::text check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909159000'
  UNION ALL
  SELECT 'tax_breakdown_relation',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*))::bigint,jsonb_build_object('relationRows',count(*))
  FROM information_schema.tables WHERE table_schema='public'
    AND table_name='backoffice_sales_invoice_tax_breakdowns'
  UNION ALL
  SELECT 'tax_breakdown_rls_state',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*))::bigint,jsonb_build_object('enabledRelations',count(*))
  FROM pg_class relation JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relname='backoffice_sales_invoice_tax_breakdowns'
    AND relation.relrowsecurity
  UNION ALL
  SELECT 'tax_breakdown_required_columns',CASE WHEN count(*)=15 THEN 'PASS' ELSE 'FAIL' END,
    abs(15-count(*))::bigint,jsonb_build_object('expected',15,'columnRows',count(*))
  FROM information_schema.columns WHERE table_schema='public'
    AND table_name='backoffice_sales_invoice_tax_breakdowns'
    AND column_name IN('company_id','invoice_id','sales_order_id','tax_group_no','tax_rule_id',
      'tax_rule_version','tax_account_id','tax_code_snapshot','tax_name_snapshot',
      'tax_rate_percent','tax_price_mode','tax_calculation_scope','tax_base_amount',
      'tax_amount','source_snapshot')
  UNION ALL
  SELECT 'tax_breakdown_runtime_routines',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    abs(3-count(*))::bigint,jsonb_build_object('expected',3,'routineRows',count(*))
  FROM (VALUES
    (to_regprocedure('private.rebuild_backoffice_sales_invoice_tax_breakdown(uuid,uuid)')),
    (to_regprocedure('private.trg_rebuild_backoffice_sales_invoice_tax_breakdown()')),
    (to_regprocedure('private.trg_guard_backoffice_sales_invoice_tax_breakdown_history()'))
  ) routine(oid) WHERE oid IS NOT NULL
  UNION ALL
  SELECT 'tax_breakdown_triggers',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(2-count(*))::bigint,jsonb_build_object('expected',2,'triggerRows',count(*))
  FROM pg_trigger trigger_state JOIN pg_class relation ON relation.oid=trigger_state.tgrelid
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND NOT trigger_state.tgisinternal
    AND trigger_state.tgname IN('backoffice_sales_invoice_tax_breakdown_rebuild',
      'backoffice_sales_invoice_tax_breakdown_history_guard')
  UNION ALL
  SELECT 'tax_breakdown_browser_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants WHERE table_schema='public'
    AND table_name='backoffice_sales_invoice_tax_breakdowns'
    AND grantee IN('anon','authenticated')
  UNION ALL
  SELECT 'private_tax_breakdown_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('browserExecutableRows',count(*))
  FROM information_schema.routine_privileges WHERE specific_schema='private'
    AND grantee IN('anon','authenticated') AND routine_name IN(
      'rebuild_backoffice_sales_invoice_tax_breakdown',
      'trg_rebuild_backoffice_sales_invoice_tax_breakdown',
      'trg_guard_backoffice_sales_invoice_tax_breakdown_history')
  UNION ALL
  SELECT 'invoice_tax_breakdown_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM (SELECT invoice.company_id,invoice.id,invoice.tax_total,
      COALESCE(sum(breakdown.tax_amount),0) breakdown_tax
    FROM public.backoffice_sales_invoices invoice
    LEFT JOIN public.backoffice_sales_invoice_tax_breakdowns breakdown
      ON breakdown.company_id=invoice.company_id AND breakdown.invoice_id=invoice.id
    GROUP BY invoice.company_id,invoice.id,invoice.tax_total) reconciled
  WHERE round(reconciled.tax_total,4)<>round(reconciled.breakdown_tax,4)
  UNION ALL
  SELECT 'tax_breakdown_tenant_lineage',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_invoice_tax_breakdowns breakdown
  LEFT JOIN public.backoffice_sales_invoices invoice ON invoice.company_id=breakdown.company_id
    AND invoice.id=breakdown.invoice_id AND invoice.sales_order_id=breakdown.sales_order_id
  LEFT JOIN public.tax_rule_versions version ON version.company_id=breakdown.company_id
    AND version.tax_rule_id=breakdown.tax_rule_id
    AND version.rule_version=breakdown.tax_rule_version
  LEFT JOIN public.chart_of_accounts account ON account.company_id=breakdown.company_id
    AND account.id=breakdown.tax_account_id
  WHERE invoice.id IS NULL OR version.id IS NULL OR account.id IS NULL
  UNION ALL
  SELECT 'tax_breakdown_runtime_inventory','INFO',0::bigint,jsonb_build_object(
    'invoiceRows',(SELECT count(*) FROM public.backoffice_sales_invoices),
    'breakdownRows',(SELECT count(*) FROM public.backoffice_sales_invoice_tax_breakdowns),
    'multiGroupInvoices',(SELECT count(*) FROM (SELECT company_id,invoice_id
      FROM public.backoffice_sales_invoice_tax_breakdowns GROUP BY company_id,invoice_id
      HAVING count(*)>1) grouped))
)
SELECT * FROM checks ORDER BY check_name;
