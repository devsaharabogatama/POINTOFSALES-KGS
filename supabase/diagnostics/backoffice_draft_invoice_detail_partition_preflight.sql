WITH required(version) AS (
  VALUES('20261006140000'),('20261105110000'),('20261105120000')
),
checks AS (
  SELECT
    'backoffice_draft_invoice_detail_partition_preflight_dependency_ledger'::text check_name,
    CASE WHEN count(*) FILTER (WHERE installed.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    count(*) FILTER (WHERE installed.version IS NULL)::bigint violation_rows,
    jsonb_build_object(
      'required',jsonb_agg(required.version ORDER BY required.version),
      'missing',COALESCE(jsonb_agg(required.version ORDER BY required.version)
        FILTER (WHERE installed.version IS NULL),'[]'::jsonb)
    ) details
  FROM required
  LEFT JOIN private.kgs_schema_migrations installed
    ON installed.version=required.version

  UNION ALL
  SELECT
    'backoffice_draft_invoice_detail_partition_preflight_installation_state',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,
    jsonb_build_object(
      'classification',CASE WHEN count(*)=0 THEN 'NOT_INSTALLED'
        ELSE 'INSTALLED_OR_PARTIAL' END,
      'ledgerRows',count(*)
    )
  FROM private.kgs_schema_migrations
  WHERE version='20261110120000'

  UNION ALL
  SELECT
    'backoffice_draft_invoice_detail_partition_preflight_runtime_anchors',
    CASE WHEN
      to_regprocedure('public.get_backoffice_sales_invoice_ui(uuid)') IS NOT NULL
      AND to_regprocedure(
        'public.get_backoffice_sales_invoice_ui_before_unified_revision(uuid)') IS NOT NULL
      AND to_regprocedure(
        'public.get_backoffice_sales_invoice_payment_context(uuid)') IS NOT NULL
      AND to_regprocedure(
        'public.get_backoffice_sales_invoice_payment_context_before_unified_revision(uuid)') IS NOT NULL
      AND md5(pg_get_functiondef(
        'public.get_backoffice_sales_invoice_ui(uuid)'::regprocedure))
        = 'ae46ab9d5fe5d1d9b34ddc90cf807bdb'
      AND md5(pg_get_functiondef(
        'public.get_backoffice_sales_invoice_payment_context(uuid)'::regprocedure))
        = 'dbe5b9307343bd03e6ea61a36490c692'
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN
      to_regprocedure('public.get_backoffice_sales_invoice_ui(uuid)') IS NOT NULL
      AND to_regprocedure(
        'public.get_backoffice_sales_invoice_ui_before_unified_revision(uuid)') IS NOT NULL
      AND to_regprocedure(
        'public.get_backoffice_sales_invoice_payment_context(uuid)') IS NOT NULL
      AND to_regprocedure(
        'public.get_backoffice_sales_invoice_payment_context_before_unified_revision(uuid)') IS NOT NULL
      AND md5(pg_get_functiondef(
        'public.get_backoffice_sales_invoice_ui(uuid)'::regprocedure))
        = 'ae46ab9d5fe5d1d9b34ddc90cf807bdb'
      AND md5(pg_get_functiondef(
        'public.get_backoffice_sales_invoice_payment_context(uuid)'::regprocedure))
        = 'dbe5b9307343bd03e6ea61a36490c692'
      THEN 0 ELSE 1 END,
    jsonb_build_object(
      'uiMd5',md5(pg_get_functiondef(
        'public.get_backoffice_sales_invoice_ui(uuid)'::regprocedure)),
      'paymentMd5',md5(pg_get_functiondef(
        'public.get_backoffice_sales_invoice_payment_context(uuid)'::regprocedure)),
      'draftPartitionPresent',position(
        'IF invoice_status<>''POSTED'' OR invoice_type<>''REGULAR'' THEN'
        IN pg_get_functiondef(
          'public.get_backoffice_sales_invoice_ui(uuid)'::regprocedure))>0
    )

  UNION ALL
  SELECT
    'backoffice_draft_invoice_detail_partition_preflight_draft_inventory',
    'INFO',0,
    jsonb_build_object(
      'draftRows',count(*),
      'withFinancialEvent',count(*) FILTER (WHERE financial_event_id IS NOT NULL),
      'meaning','Inventory only; zero rows is not behavioral proof'
    )
  FROM public.backoffice_sales_invoices
  WHERE status='DRAFT'

  UNION ALL
  SELECT
    'backoffice_draft_invoice_detail_partition_preflight_business_boundary',
    'INFO',0,
    jsonb_build_object(
      'changed',jsonb_build_array(
        'Draft/non-regular Invoice detail read partition',
        'Draft/non-regular payment-context read partition'),
      'preserved',jsonb_build_array(
        'Posted regular unified revision overlay','Invoice posting writer',
        'Customer Receipt and AR allocation','SO/Delivery/Stock/FIFO/HPP',
        'POS Retail','historical rows'),
      'mutation','NONE'
    )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY check_name;
