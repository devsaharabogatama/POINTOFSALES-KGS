-- READ ONLY. Run this entire SELECT in SQL Editor and export all result rows.
-- This is runtime discovery, NOT migration preflight or behavioral PASS.
-- Uses PostgreSQL catalogs only: no business rows, secrets or mutation.
WITH target_relations(schema_name, relation_name) AS (
  VALUES
    ('public','backoffice_sales_invoices'),
    ('public','backoffice_sales_invoice_lines'),
    ('public','backoffice_sales_invoice_audit'),
    ('public','backoffice_sales_invoice_receivable_schedules'),
    ('public','backoffice_sales_down_payment_applications'),
    ('public','backoffice_sales_invoice_price_corrections'),
    ('public','backoffice_sales_invoice_price_correction_lines'),
    ('public','backoffice_sales_invoice_price_correction_operations'),
    ('public','customer_receipt_documents'),
    ('public','customer_receipt_backoffice_invoice_allocations'),
    ('public','backoffice_sales_credit_notes'),
    ('public','backoffice_sales_customer_refunds'),
    ('public','financial_events'),
    ('public','finance_journals'),
    ('public','finance_journal_lines'),
    ('public','accounting_periods'),
    ('private','kgs_schema_migrations')
), relations AS (
  SELECT target.schema_name,target.relation_name,relation.oid
  FROM target_relations target
  LEFT JOIN pg_catalog.pg_namespace namespace ON namespace.nspname=target.schema_name
  LEFT JOIN pg_catalog.pg_class relation ON relation.relnamespace=namespace.oid
    AND relation.relname=target.relation_name AND relation.relkind IN('r','p','v','m')
), routine_targets(routine_name) AS (
  VALUES
    ('post_backoffice_sales_invoice_price_correction'),
    ('get_backoffice_sales_invoice_price_correction_context'),
    ('backoffice_invoice_effective_entered_unit_price'),
    ('backoffice_invoice_effective_line_amounts'),
    ('backoffice_invoice_effective_total'),
    ('backoffice_invoice_price_delta'),
    ('backoffice_invoice_receivable_before_receipts'),
    ('rebuild_backoffice_invoice_effective_schedules'),
    ('reconcile_backoffice_invoice_receivable_schedule'),
    ('backoffice_sales_invoice_ui_snapshot'),
    ('backoffice_sales_invoice_ui_snapshot_before_price_correction'),
    ('backoffice_sales_invoice_snapshot'),
    ('get_backoffice_sales_invoice_payment_context'),
    ('save_customer_receipt_allocated_draft'),
    ('post_customer_receipt_allocated'),
    ('post_customer_receipt_financial_event_core'),
    ('get_finance_customer_receipts'),
    ('get_finance_ar_aging'),
    ('get_finance_customer_statement'),
    ('allocate_backoffice_sales_return_invoices_before_retained'),
    ('get_sales_export_net_detail_core'),
    ('export_sales_documents_with_reconciliation')
), routines AS (
  SELECT proc.oid,namespace.nspname,proc.proname,proc.prosecdef,proc.proconfig,
    pg_catalog.pg_get_function_identity_arguments(proc.oid) arguments,
    pg_catalog.pg_get_functiondef(proc.oid) definition
  FROM pg_catalog.pg_proc proc
  JOIN pg_catalog.pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE namespace.nspname IN('public','private') AND proc.prokind='f'
    AND (proc.proname IN(SELECT target.routine_name FROM routine_targets target)
      OR EXISTS(SELECT 1 FROM relations relation
        JOIN pg_catalog.pg_trigger trigger ON trigger.tgrelid=relation.oid
        WHERE NOT trigger.tgisinternal AND trigger.tgfoid=proc.oid))
), report AS (
  SELECT '01_relation'::text section,
    relation.schema_name||'.'||relation.relation_name object_name,
    CASE WHEN relation.oid IS NULL THEN 'MISSING' ELSE 'FOUND' END status,
    jsonb_build_object('columns',COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'name',attribute.attname,
        'type',pg_catalog.format_type(attribute.atttypid,attribute.atttypmod),
        'notNull',attribute.attnotnull,
        'default',pg_catalog.pg_get_expr(def.adbin,def.adrelid)) ORDER BY attribute.attnum)
      FROM pg_catalog.pg_attribute attribute
      LEFT JOIN pg_catalog.pg_attrdef def ON def.adrelid=attribute.attrelid
        AND def.adnum=attribute.attnum
      WHERE attribute.attrelid=relation.oid AND attribute.attnum>0
        AND NOT attribute.attisdropped),'[]'::jsonb)) details
  FROM relations relation
  UNION ALL
  SELECT '02_constraint',relation.schema_name||'.'||relation.relation_name,
    'OBSERVED',jsonb_build_object('name',con.conname,
      'definition',pg_catalog.pg_get_constraintdef(con.oid,true))
  FROM relations relation
  JOIN pg_catalog.pg_constraint con ON con.conrelid=relation.oid
  UNION ALL
  SELECT '03_trigger',relation.schema_name||'.'||relation.relation_name,
    'OBSERVED',jsonb_build_object('name',trigger.tgname,'enabled',trigger.tgenabled,
      'definition',pg_catalog.pg_get_triggerdef(trigger.oid,true))
  FROM relations relation
  JOIN pg_catalog.pg_trigger trigger ON trigger.tgrelid=relation.oid
  WHERE NOT trigger.tgisinternal
  UNION ALL
  SELECT '04_routine',routine.nspname||'.'||routine.proname||'('||routine.arguments||')',
    'OBSERVED',jsonb_build_object('definition',routine.definition,
      'definitionMd5',md5(routine.definition),'securityDefiner',routine.prosecdef,
      'configuration',routine.proconfig)
  FROM routines routine
  UNION ALL
  SELECT '05_missing_routine',target.routine_name,'MISSING',
    jsonb_build_object('meaning','Not found by name; investigate actual signature or replacement')
  FROM routine_targets target
  WHERE NOT EXISTS(SELECT 1 FROM routines routine WHERE routine.proname=target.routine_name)
)
SELECT section,object_name,status,details
FROM report
ORDER BY section,object_name,details->>'name';
