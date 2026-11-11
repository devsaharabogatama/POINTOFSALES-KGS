-- READ ONLY. Run before 20261110100000.
BEGIN READ ONLY;

WITH dependency AS (
  SELECT count(*) installed_count,array_agg(version ORDER BY version) installed
  FROM private.kgs_schema_migrations
  WHERE version IN('20261105100000','20261105110000','20261105120000',
    '20261106100000','20261110140000')
), installation AS (
  SELECT count(*) object_count,
    jsonb_agg(name) FILTER(WHERE name IS NOT NULL) objects
  FROM (SELECT version name FROM private.kgs_schema_migrations
      WHERE version='20261110100000'
    UNION ALL SELECT column_name FROM information_schema.columns
      WHERE table_schema='public' AND table_name='backoffice_sales_invoices'
        AND column_name IN('replacement_credit_note_id','replacement_source_invoice_id')
    UNION ALL SELECT to_regprocedure(
      'public.post_backoffice_credit_note_create_replacement_invoice(uuid,bigint,uuid)')::text) state
  WHERE name IS NOT NULL
), anchor AS (
  SELECT
    md5(pg_get_functiondef(
      'public.save_backoffice_sales_invoice_draft(uuid,bigint,uuid,uuid,jsonb)'::regprocedure)) save_md5,
    md5(pg_get_functiondef(
      'private.ar3_post_backoffice_sales_invoice_core(uuid,bigint,uuid)'::regprocedure)) post_md5,
    md5(pg_get_functiondef(
      'private.post_backoffice_sales_credit_note_before_retained(uuid,bigint,uuid)'::regprocedure)) credit_md5,
    md5(pg_get_functiondef(
      'public.post_backoffice_sales_credit_note(uuid,bigint,uuid)'::regprocedure)) public_credit_md5,
    md5(pg_get_functiondef(
      'public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)'::regprocedure)) apply_md5
), process_boundary AS (
  SELECT
    count(*) FILTER(WHERE setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
      AND public.private_company_feature_enabled(
        setting.company_id,'tax_sales_enabled')) tax_enabled_count,
    jsonb_agg(jsonb_build_object('code',company.company_code,
      'mode',setting.active_mode,'taxSalesEnabled',
      public.private_company_feature_enabled(company.id,'tax_sales_enabled'))
      ORDER BY company.company_code) companies
  FROM public.company_sales_process_settings setting
  JOIN public.companies company ON company.id=setting.company_id
    AND company.status='ACTIVE'
), runtime_boundary AS (
  SELECT
    (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) active_queue,
    (SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) offline
), checks AS (
  SELECT 1 ordinal,
    'backoffice_ar_credit_note_replacement_preflight_dependency_ledger'::text check_name,
    CASE WHEN installed_count=5 THEN 'PASS' ELSE 'BLOCKER' END::text status,
    CASE WHEN installed_count=5 THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('required',ARRAY['20261105100000','20261105110000',
      '20261105120000','20261106100000','20261110140000'],
      'installed',installed) details
  FROM dependency

  UNION ALL

  SELECT 2,
    'backoffice_ar_credit_note_replacement_preflight_installation_state',
    CASE WHEN object_count=0 THEN 'PASS' ELSE 'BLOCKER' END,
    object_count,
    jsonb_build_object('classification',CASE WHEN object_count=0
      THEN 'NOT_INSTALLED' ELSE 'PARTIAL/INCONSISTENT' END,'objects',objects)
  FROM installation

  UNION ALL

  SELECT 3,
    'backoffice_ar_credit_note_replacement_preflight_runtime_anchors',
    CASE WHEN save_md5='91a423d2fb08901b7596f3b048c84cd2'
        AND post_md5='c874b7d081b9781004eaf42522bda1d0'
        AND credit_md5='3ce005460e7e50ec4b9d9134e5e4a928'
        AND public_credit_md5='93723ceab34fd6318088f314e976dd72'
        AND apply_md5='1f3eb44dda2997282789da828e31fa81'
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN save_md5='91a423d2fb08901b7596f3b048c84cd2'
        AND post_md5='c874b7d081b9781004eaf42522bda1d0'
        AND credit_md5='3ce005460e7e50ec4b9d9134e5e4a928'
        AND public_credit_md5='93723ceab34fd6318088f314e976dd72'
        AND apply_md5='1f3eb44dda2997282789da828e31fa81'
      THEN 0 ELSE 1 END,
    to_jsonb(anchor)
  FROM anchor

  UNION ALL

  SELECT 4,
    'backoffice_ar_credit_note_replacement_preflight_process_boundary',
    CASE WHEN tax_enabled_count=0 THEN 'PASS' ELSE 'BLOCKER' END,
    tax_enabled_count,
    jsonb_build_object('companies',companies)
  FROM process_boundary

  UNION ALL

  SELECT 5,
    'backoffice_ar_credit_note_replacement_preflight_runtime_boundary',
    CASE WHEN active_queue=0 AND offline=0 THEN 'PASS' ELSE 'BLOCKER' END,
    active_queue+offline,
    jsonb_build_object('activeFinanceQueue',active_queue,
      'nonterminalOffline',offline)
  FROM runtime_boundary

  UNION ALL

  SELECT 6,
    'backoffice_ar_credit_note_replacement_preflight_business_boundary',
    'INFO',0,
    jsonb_build_object(
      'changed',ARRAY['native Backoffice combined Credit Note/replacement action',
        'replacement Invoice Draft edit/post lineage'],
      'preserved',ARRAY['plain Credit Note post','ordinary Invoice qty counters',
        'POS/retained Retail','Dispatch/Stock/FIFO/HPP','historical Journals',
        'old Receipt and Down Payment settlement'])
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY ordinal;

ROLLBACK;
