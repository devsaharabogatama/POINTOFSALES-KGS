-- SELECT-only postflight after migration.
WITH definition AS (
  SELECT pg_get_functiondef(
    'private.acp5h_post_sales_return_core(uuid,bigint,uuid)'::regprocedure) body
), invalid AS (
  SELECT document.id FROM public.sales_return_documents document
  JOIN public.sales_headers sale ON sale.company_id=document.company_id
    AND sale.id=document.source_sales_id
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=document.company_id
  WHERE document.approval_mode_snapshot='OPTIONAL'
    AND document.direct_pos_request_hash IS NOT NULL
    AND (sale.sales_origin<>'POS'
      OR sale.sales_process_mode<>'RETAIL_CONFIRM_INVOICE'
      OR setting.active_mode<>'RETAIL_CONFIRM_INVOICE')
)
SELECT 'pos_retail_direct_return_postflight_migration_ledger' check_name,
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
  abs(count(*)-1) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
FROM private.kgs_schema_migrations WHERE version='20261102100000'
UNION ALL
SELECT 'pos_retail_direct_return_postflight_runtime_contract',
  CASE WHEN to_regprocedure('public.submit_pos_sales_return_with_delivery_fee(uuid,uuid,text,text,jsonb,jsonb,boolean,uuid)') IS NOT NULL
      AND body LIKE '%direct_pos_request_hash%'
      AND body LIKE '%setting.active_mode=''RETAIL_CONFIRM_INVOICE''%'
      AND body LIKE '%source_sale.sales_origin=''POS''%'
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN to_regprocedure('public.submit_pos_sales_return_with_delivery_fee(uuid,uuid,text,text,jsonb,jsonb,boolean,uuid)') IS NOT NULL
      AND body LIKE '%direct_pos_request_hash%'
      AND body LIKE '%setting.active_mode=''RETAIL_CONFIRM_INVOICE''%'
      AND body LIKE '%source_sale.sales_origin=''POS''%'
    THEN 0 ELSE 1 END,
  jsonb_build_object('submitRpc',to_regprocedure('public.submit_pos_sales_return_with_delivery_fee(uuid,uuid,text,text,jsonb,jsonb,boolean,uuid)')::text,
    'optionalGuard',body LIKE '%direct_pos_request_hash%') FROM definition
UNION ALL
SELECT 'pos_retail_direct_return_postflight_process_boundary',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('invalidRows',count(*)) FROM invalid
UNION ALL
SELECT 'pos_retail_direct_return_postflight_historical_boundary',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('historicalRequiredWithDirectHash',count(*))
FROM public.sales_return_documents
WHERE approval_mode_snapshot='REQUIRED' AND direct_pos_request_hash IS NOT NULL
UNION ALL
SELECT 'pos_retail_direct_return_postflight_business_boundary','INFO',0,
  jsonb_build_object('changed',jsonb_build_array(
      'POS + RETAIL_CONFIRM_INVOICE Return/refund confirms atomically'),
    'preserved',jsonb_build_array(
      'BACKOFFICE_DELIVERED_QTY_INVOICE Draft approval',
      'retained Retail Backoffice return bridge','historical Draft/Posted',
      'Finance automatic/controlled posting policy','Stock/FIFO canonical core'),
    'next','Run rollback-only behavior test, then deploy client only after explicit authorization');
