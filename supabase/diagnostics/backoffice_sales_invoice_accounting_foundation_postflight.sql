-- Read-only verification after gate 20260909156000.
WITH results AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909156000'
  UNION ALL
  SELECT 'required_invoice_foundation_relations',CASE WHEN count(*)=9 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-9)::bigint,jsonb_build_object('expected',9,'relationRows',count(*))
  FROM information_schema.tables WHERE table_schema='public' AND table_name IN(
    'backoffice_sales_payment_terms','backoffice_sales_payment_term_lines',
    'backoffice_sales_proformas','backoffice_sales_invoices','backoffice_sales_invoice_lines',
    'backoffice_sales_invoice_quantity_allocations','backoffice_sales_down_payment_applications',
    'backoffice_sales_invoice_receivable_schedules','backoffice_sales_invoice_audit')
  UNION ALL
  SELECT 'required_sales_order_payment_term_columns',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-2)::bigint,jsonb_build_object('expected',2,'columnRows',count(*))
  FROM information_schema.columns WHERE table_schema='public'
    AND table_name='backoffice_sales_orders'
    AND column_name IN('payment_term_id','payment_term_snapshot')
  UNION ALL
  SELECT 'invoice_foundation_rls_state',CASE WHEN count(*)=9 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-9)::bigint,jsonb_build_object('enabledRelations',count(*))
  FROM pg_class relation JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relrowsecurity AND relation.relname IN(
    'backoffice_sales_payment_terms','backoffice_sales_payment_term_lines',
    'backoffice_sales_proformas','backoffice_sales_invoices','backoffice_sales_invoice_lines',
    'backoffice_sales_invoice_quantity_allocations','backoffice_sales_down_payment_applications',
    'backoffice_sales_invoice_receivable_schedules','backoffice_sales_invoice_audit')
  UNION ALL
  SELECT 'browser_invoice_foundation_table_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants WHERE grantee IN('anon','authenticated')
    AND table_schema='public' AND table_name IN(
      'backoffice_sales_payment_terms','backoffice_sales_payment_term_lines',
      'backoffice_sales_proformas','backoffice_sales_invoices','backoffice_sales_invoice_lines',
      'backoffice_sales_invoice_quantity_allocations','backoffice_sales_down_payment_applications',
      'backoffice_sales_invoice_receivable_schedules','backoffice_sales_invoice_audit')
  UNION ALL
  SELECT 'invoice_foundation_zero_backfill',CASE WHEN row_count=0 THEN 'PASS' ELSE 'FAIL' END,
    row_count::bigint,jsonb_build_object('foundationRows',row_count)
  FROM (SELECT
    (SELECT count(*) FROM public.backoffice_sales_payment_terms)
    +(SELECT count(*) FROM public.backoffice_sales_payment_term_lines)
    +(SELECT count(*) FROM public.backoffice_sales_proformas)
    +(SELECT count(*) FROM public.backoffice_sales_invoices)
    +(SELECT count(*) FROM public.backoffice_sales_invoice_lines)
    +(SELECT count(*) FROM public.backoffice_sales_invoice_quantity_allocations)
    +(SELECT count(*) FROM public.backoffice_sales_down_payment_applications)
    +(SELECT count(*) FROM public.backoffice_sales_invoice_receivable_schedules)
    +(SELECT count(*) FROM public.backoffice_sales_invoice_audit) row_count) tally
  UNION ALL
  SELECT 'invoice_foundation_finance_zero_effect',CASE WHEN event_count=0 AND journal_count=0
      THEN 'PASS' ELSE 'FAIL' END,(event_count+journal_count)::bigint,
    jsonb_build_object('foundationEvents',event_count,'foundationJournals',journal_count)
  FROM (SELECT
    (SELECT count(*) FROM public.financial_events
      WHERE source_table IN('backoffice_sales_invoices','backoffice_sales_proformas')) event_count,
    (SELECT count(*) FROM public.finance_journals
      WHERE source_type IN('backoffice_sales_invoices','backoffice_sales_proformas')) journal_count) tally
), inventory AS (
  SELECT 'invoice_foundation_runtime_inventory'::text check_name,'INFO'::text status,
    0::bigint violation_rows,jsonb_build_object(
      'invoiceableLines',(SELECT count(*) FROM public.backoffice_sales_order_lines
        WHERE to_invoice_base_qty>0),
      'invoiceableBaseQty',(SELECT COALESCE(sum(to_invoice_base_qty),0)
        FROM public.backoffice_sales_order_lines),
      'foundationOnly',true) details
)
SELECT * FROM (SELECT * FROM results UNION ALL SELECT * FROM inventory) output
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
