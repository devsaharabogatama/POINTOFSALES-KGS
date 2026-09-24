-- Read-only gate after exact LSM activation.
WITH enabled AS (
  SELECT setting.company_id,company.company_name,setting.replenishment_mode,
    setting.auto_ro_stock_match_enabled
  FROM public.company_purchase_replenishment_settings setting
  JOIN public.companies company ON company.id=setting.company_id
  WHERE setting.auto_ro_stock_match_enabled
)
SELECT 'lsm_auto_ro_stock_match_policy_scope' check_name,
  CASE WHEN count(*)=1
      AND min(company_id)='07bdffb9-8c56-444c-a49b-81ac86745674'::uuid
      AND min(company_name)='Latorti Sari Median'
      AND min(replenishment_mode)='AUTO_RO' THEN 'PASS' ELSE 'FAIL' END status,
  CASE WHEN count(*)=1
      AND min(company_id)='07bdffb9-8c56-444c-a49b-81ac86745674'::uuid
      AND min(company_name)='Latorti Sari Median'
      AND min(replenishment_mode)='AUTO_RO' THEN 0 ELSE 1 END::bigint violation_rows,
  jsonb_build_object('enabledCompanies',coalesce(jsonb_agg(company_name),'[]'::jsonb)) details
FROM enabled
UNION ALL
SELECT 'lsm_auto_ro_stock_match_policy_audit',
  CASE WHEN count(*)>0 THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint,
  jsonb_build_object('rows',count(*),'latestAt',max(created_at))
FROM public.company_purchase_replenishment_setting_audit
WHERE company_id='07bdffb9-8c56-444c-a49b-81ac86745674'::uuid
  AND action='STOCK_MATCH_POLICY_CHANGE'
UNION ALL
SELECT 'lsm_auto_ro_stock_match_draft_inventory','INFO',0,
  jsonb_build_object('rows',count(*),'matchedRows',count(*) FILTER(
    WHERE stock_match_operation_id IS NOT NULL),'drafts',coalesce(jsonb_agg(
      jsonb_build_object('batchNo',batch_no,'businessDate',business_date,
        'version',master_version,'matchedAt',stock_matched_at)
      ORDER BY business_date,batch_no),'[]'::jsonb))
FROM public.purchase_daily_batches
WHERE company_id='07bdffb9-8c56-444c-a49b-81ac86745674'::uuid
  AND mode_snapshot='AUTO_RO' AND status='DRAFT'
UNION ALL
SELECT 'lsm_auto_ro_stock_match_runtime_reconciliation',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
  jsonb_build_object('invalidMatchedDrafts',count(*))
FROM public.purchase_daily_batches batch
CROSS JOIN LATERAL (SELECT private.get_purchase_daily_auto_ro_stock_match_core(
  batch.company_id,batch.id) preview) matched
WHERE batch.company_id='07bdffb9-8c56-444c-a49b-81ac86745674'::uuid
  AND batch.mode_snapshot='AUTO_RO' AND batch.status='DRAFT'
  AND batch.stock_match_operation_id IS NOT NULL
  AND (NOT coalesce((matched.preview->>'isMatched')::boolean,false)
    OR jsonb_array_length(matched.preview->'changes')>0);
