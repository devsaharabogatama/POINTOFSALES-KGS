WITH definitions AS (
  SELECT
    pg_get_functiondef(
      'public.get_backoffice_sales_invoice_ui(uuid)'::regprocedure) ui,
    pg_get_functiondef(
      'public.get_backoffice_sales_invoice_payment_context(uuid)'::regprocedure) payment
),
checks AS (
  SELECT
    'backoffice_draft_invoice_detail_partition_postflight_migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations
  WHERE version='20261110120000'

  UNION ALL
  SELECT
    'backoffice_draft_invoice_detail_partition_postflight_runtime_contract',
    CASE WHEN
      position('IF invoice_status<>''POSTED'' OR invoice_type<>''REGULAR'' THEN'
        IN ui)>0
      AND position('RETURN base;' IN ui)>0
      AND position('get_backoffice_invoice_revision_context(p_invoice_id)'
        IN ui)>0
      AND position('IF invoice_status<>''POSTED'' OR invoice_type<>''REGULAR'' THEN'
        IN payment)>0
      AND position('RETURN base;' IN payment)>0
      AND position('get_backoffice_invoice_revision_context(p_invoice_id)'
        IN payment)>0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN
      position('IF invoice_status<>''POSTED'' OR invoice_type<>''REGULAR'' THEN'
        IN ui)>0
      AND position('RETURN base;' IN ui)>0
      AND position('get_backoffice_invoice_revision_context(p_invoice_id)'
        IN ui)>0
      AND position('IF invoice_status<>''POSTED'' OR invoice_type<>''REGULAR'' THEN'
        IN payment)>0
      AND position('RETURN base;' IN payment)>0
      AND position('get_backoffice_invoice_revision_context(p_invoice_id)'
        IN payment)>0
      THEN 0 ELSE 1 END,
    jsonb_build_object('uiMd5',md5(ui),'paymentMd5',md5(payment),
      'draftBasePartition',true,'postedRegularOverlay',true)
  FROM definitions

  UNION ALL
  SELECT
    'backoffice_draft_invoice_detail_partition_postflight_data_contract',
    CASE WHEN count(*) FILTER (WHERE status='DRAFT'
      AND financial_event_id IS NOT NULL)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER (WHERE status='DRAFT'
      AND financial_event_id IS NOT NULL)::bigint,
    jsonb_build_object(
      'draftRows',count(*) FILTER (WHERE status='DRAFT'),
      'invalidDraftEvents',count(*) FILTER (WHERE status='DRAFT'
        AND financial_event_id IS NOT NULL))
  FROM public.backoffice_sales_invoices

  UNION ALL
  SELECT
    'backoffice_draft_invoice_detail_partition_postflight_business_boundary',
    'INFO',0,
    jsonb_build_object(
      'changed',jsonb_build_array(
        'Draft/non-regular Invoice UI read partition',
        'Draft/non-regular payment-context read partition'),
      'preserved',jsonb_build_array(
        'Posted regular unified revision overlay','Invoice posting writer',
        'Customer Receipt and AR allocation','SO/Delivery/Stock/FIFO/HPP',
        'POS Retail','historical rows'),
      'next','Run rollback-only behavior and authenticated Draft-to-Posted UI smoke')
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY check_name;
