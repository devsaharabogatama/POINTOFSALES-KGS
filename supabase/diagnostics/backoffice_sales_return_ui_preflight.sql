-- SELECT-only preflight for Backoffice Sales Return Step 5/5 UI read models.
WITH checks AS (
  SELECT 'return_ui_dependency_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(1-count(*))::bigint violation_rows,
    jsonb_build_object('requiredVersion','20260917151000','ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260917151000'
  UNION ALL
  SELECT 'return_ui_routine_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,
    jsonb_build_object('existing',COALESCE(jsonb_agg(candidate.signature),'[]'::jsonb))
  FROM (VALUES
    ('public.get_backoffice_sales_return_receipt_workspace()'),
    ('public.get_backoffice_sales_return_links(uuid)'),
    ('public.get_backoffice_sales_return_activity(uuid)')) candidate(signature)
  WHERE to_regprocedure(candidate.signature) IS NOT NULL
  UNION ALL
  SELECT 'return_ui_source_relation_contract',
    CASE WHEN count(*)=8 THEN 'PASS' ELSE 'BLOCKER' END,
    (8-count(*))::bigint,
    jsonb_build_object('present',count(*),'expected',8)
  FROM (VALUES
    ('backoffice_sales_returns'),('backoffice_sales_return_audit'),
    ('backoffice_sales_return_receipts'),('backoffice_sales_return_receipt_audit'),
    ('backoffice_sales_credit_notes'),('backoffice_sales_credit_note_audit'),
    ('backoffice_sales_customer_refunds'),('backoffice_sales_customer_refund_audit')) required(name)
  WHERE to_regclass('public.'||required.name) IS NOT NULL
  UNION ALL
  SELECT 'return_ui_runtime_inventory','INFO',0,
    jsonb_build_object('returns',(SELECT count(*) FROM public.backoffice_sales_returns),
      'receipts',(SELECT count(*) FROM public.backoffice_sales_return_receipts),
      'creditNotes',(SELECT count(*) FROM public.backoffice_sales_credit_notes),
      'refunds',(SELECT count(*) FROM public.backoffice_sales_customer_refunds))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
