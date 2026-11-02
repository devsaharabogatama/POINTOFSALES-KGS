-- SELECT-only preflight for the process-aware POS Retail Pickup document fix.
WITH
scope AS (
  SELECT company.id AS company_id,company.company_code,company.company_name,
         setting.active_mode,
         COALESCE(branding.delivery_document_creation_policy,'DELIVERY_ONLY')
           AS creation_policy
  FROM public.companies company
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=company.id
  LEFT JOIN public.company_branding_profiles branding
    ON branding.company_id=company.id
  WHERE company.company_code='KGS' AND company.status='ACTIVE'
),
sale_scope AS (
  SELECT sale.* FROM public.sales_headers sale
  JOIN scope ON scope.company_id=sale.company_id
  WHERE sale.draft_no='DRF-20261030-000455'
),
runtime AS (
  SELECT pg_get_functiondef(
    'private.ensure_sales_documents(uuid,uuid,text)'::regprocedure) definition
),
checks AS (
  SELECT 10 seq,'pos_retail_pickup_document_preflight_identity'::text check_name,
    CASE WHEN (SELECT count(*) FROM scope WHERE active_mode='RETAIL_CONFIRM_INVOICE')=1
           AND (SELECT count(*) FROM sale_scope)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    CASE WHEN (SELECT count(*) FROM scope WHERE active_mode='RETAIL_CONFIRM_INVOICE')=1
           AND (SELECT count(*) FROM sale_scope)=1 THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('company',(SELECT jsonb_agg(to_jsonb(scope)) FROM scope),
      'sale',(SELECT jsonb_agg(jsonb_build_object('id',sale.id,'draftNo',sale.draft_no,
        'documentStatus',sale.document_status,'orderRuntimeStatus',sale.order_runtime_status,
        'salesOrigin',sale.sales_origin,'salesProcessMode',sale.sales_process_mode,
        'fulfillmentMode',sale.fulfillment_mode,'sjRequired',sale.sj_required,
        'masterVersion',sale.master_version)) FROM sale_scope sale)) details
  UNION ALL
  SELECT 20,'pos_retail_pickup_document_preflight_dependency_ledger',
    CASE WHEN (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260827153000','20260910153000','20261030120000'))=3
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260827153000','20260910153000','20261030120000'))=3
      THEN 0 ELSE 1 END,
    jsonb_build_object('required',jsonb_build_array('20260827153000',
      '20260910153000','20261030120000'),'installed',(SELECT count(*)
      FROM private.kgs_schema_migrations WHERE version IN('20260827153000',
        '20260910153000','20261030120000')))
  UNION ALL
  SELECT 30,'pos_retail_pickup_document_preflight_installation_state',
    CASE WHEN (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20261030130000')=0
      AND definition NOT LIKE '%POS_RETAIL_PICKUP_DOCUMENT_BOUNDARY%'
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20261030130000')=0
      AND definition NOT LIKE '%POS_RETAIL_PICKUP_DOCUMENT_BOUNDARY%'
      THEN 0 ELSE 1 END,
    jsonb_build_object('state',CASE
      WHEN (SELECT count(*) FROM private.kgs_schema_migrations
        WHERE version='20261030130000')=0
       AND definition NOT LIKE '%POS_RETAIL_PICKUP_DOCUMENT_BOUNDARY%'
      THEN 'NOT_INSTALLED' ELSE 'PARTIAL_OR_INSTALLED' END,
      'ledgerRows',(SELECT count(*) FROM private.kgs_schema_migrations
        WHERE version='20261030130000'))
  FROM runtime
  UNION ALL
  SELECT 40,'pos_retail_pickup_document_preflight_runtime_anchor',
    CASE WHEN definition LIKE '%delivery_document_creation_policy%'
      AND definition LIKE '%private.sales_delivery_document_required(%'
      AND definition LIKE '%v_delivery_id IS NOT NULL%'
      AND definition ~ 'v_sale[.]fulfillment_mode[[:space:]]*=[[:space:]]*''DELIVERY'''
      AND definition NOT LIKE '%POS_RETAIL_PICKUP_DOCUMENT_BOUNDARY%'
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN definition LIKE '%delivery_document_creation_policy%'
      AND definition LIKE '%private.sales_delivery_document_required(%'
      AND definition LIKE '%v_delivery_id IS NOT NULL%'
      AND definition ~ 'v_sale[.]fulfillment_mode[[:space:]]*=[[:space:]]*''DELIVERY'''
      AND definition NOT LIKE '%POS_RETAIL_PICKUP_DOCUMENT_BOUNDARY%'
      THEN 0 ELSE 1 END,
    jsonb_build_object('function','private.ensure_sales_documents(uuid,uuid,text)',
      'currentPolicyConsumer',definition LIKE '%delivery_document_creation_policy%',
      'currentBoundaryMarker',definition LIKE '%POS_RETAIL_PICKUP_DOCUMENT_BOUNDARY%')
  FROM runtime
  UNION ALL
  SELECT 50,'pos_retail_pickup_document_preflight_exact_conflict',
    CASE WHEN scope.creation_policy='ALL_POSTED_SALES'
      AND sale.fulfillment_mode='PICKUP' AND NOT sale.sj_required
      AND sale.sales_origin='POS'
      AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
      AND sale.document_status='DRAFT'
      AND sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED')
      THEN 'ROOT_CAUSE' ELSE 'BLOCKER' END,
    CASE WHEN scope.creation_policy='ALL_POSTED_SALES'
      AND sale.fulfillment_mode='PICKUP' AND NOT sale.sj_required
      AND sale.sales_origin='POS'
      AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
      AND sale.document_status='DRAFT'
      AND sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED')
      THEN 0 ELSE 1 END,
    jsonb_build_object('creationPolicy',scope.creation_policy,
      'runtimeCurrentlyCreatesDelivery',true,
      'target','POS Retail Pickup creates Invoice without Delivery Document')
  FROM scope JOIN sale_scope sale ON sale.company_id=scope.company_id
  UNION ALL
  SELECT 60,'pos_retail_pickup_document_preflight_runtime_boundary',
    CASE WHEN NOT EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
        WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))
      AND NOT EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
        WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION'))
      THEN 'PASS' ELSE 'BLOCKER' END,
    (SELECT count(*) FROM public.finance_posting_queue_runs
       WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))
      +(SELECT count(*) FROM public.pos_offline_sale_submissions
       WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')),
    jsonb_build_object('activeFinanceQueue',(SELECT count(*)
      FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')),
      'nonterminalOffline',(SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')))
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY seq;
