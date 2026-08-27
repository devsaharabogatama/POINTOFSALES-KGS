-- Invoice date display policy preflight.
-- SAFETY: SELECT-only.
WITH checks AS (
  SELECT 'invoice_date_policy_dependency' check_name,
    CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260820120000') THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('requiredVersion','20260820120000') details
  UNION ALL
  SELECT 'invoice_date_source_readiness',
    CASE WHEN count(*) FILTER(WHERE sale.transaction_date IS NULL
      OR sale.posted_at IS NULL)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('postedSales',count(*),
      'invalidRows',count(*) FILTER(WHERE sale.transaction_date IS NULL
        OR sale.posted_at IS NULL))
  FROM public.sales_headers sale WHERE sale.document_status='POSTED'
  UNION ALL
  SELECT 'invoice_date_policy_schema_state','SETUP',jsonb_build_object(
    'brandingColumnExists',EXISTS(SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='company_branding_profiles'
        AND column_name='invoice_date_display_mode'),
    'expectedModes',jsonb_build_array('ORDER_DATE','POSTED_DATE'))
  UNION ALL
  SELECT 'invoice_snapshot_policy_state','SETUP',jsonb_build_object(
    'snapshots',count(*),
    'snapshotsWithPolicy',count(*) FILTER(
      WHERE snapshot_payload->'branding'->>'invoiceDateDisplayMode'
        IN('ORDER_DATE','POSTED_DATE')))
  FROM public.sales_invoice_snapshots
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
