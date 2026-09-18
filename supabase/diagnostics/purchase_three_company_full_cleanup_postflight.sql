-- SELECT-only postflight for the KMS/SMS/LSM controlled procurement cleanup.
-- Expected after a successful operation: every row is PASS/INFO, old active
-- coverage is zero, modes remain AUTO_RO, and the one received KMS PO remains.

WITH target_company(company_id,expected_name,short_code) AS (
  VALUES
    ('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,
      'Khadijah Muda Sejahtera'::text,'KMS'::text),
    ('809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid,
      'Smart Muda Solusi'::text,'SMS'::text),
    ('07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,
      'Latorti Sari Median'::text,'LSM'::text)
), company_scope AS (
  SELECT target.*,company.company_name,company.status,
    setting.replenishment_mode,setting.cutoff_local_time
  FROM target_company target
  LEFT JOIN public.companies company ON company.id=target.company_id
  LEFT JOIN public.company_purchase_replenishment_settings setting
    ON setting.company_id=target.company_id
), active_order AS (
  SELECT document.*
  FROM public.supplier_order_documents document
  WHERE document.company_id IN(SELECT company_id FROM target_company)
    AND document.status IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')
), active_request AS (
  SELECT document.*
  FROM public.stock_request_documents document
  WHERE document.company_id IN(SELECT company_id FROM target_company)
    AND document.status IN('DRAFT','SUBMITTED','ORDERED','PARTIALLY_RECEIVED')
), preview AS (
  SELECT target.short_code,core.preview
  FROM target_company target
  JOIN public.companies company ON company.id=target.company_id
  CROSS JOIN LATERAL (SELECT
    private.get_purchase_daily_replenishment_candidates_core(
      target.company_id,(clock_timestamp() AT TIME ZONE company.timezone)::date) preview
  ) core
), preview_line AS (
  SELECT preview.short_code,candidate
  FROM preview
  CROSS JOIN LATERAL jsonb_array_elements(preview.preview->'candidates') candidate
), checks AS (
  SELECT 10 sort_key,'cleanup_company_mode'::text check_name,
    CASE WHEN count(*)=3 AND count(*) FILTER(WHERE company_name=expected_name
        AND status='ACTIVE' AND replenishment_mode='AUTO_RO')=3
      THEN 'PASS' ELSE 'FAIL' END status,
    count(*) FILTER(WHERE company_name IS DISTINCT FROM expected_name
      OR status IS DISTINCT FROM 'ACTIVE'
      OR replenishment_mode IS DISTINCT FROM 'AUTO_RO')::bigint violation_rows,
    jsonb_build_object('companies',jsonb_agg(to_jsonb(company_scope)
      ORDER BY short_code),'requiredMode','AUTO_RO') details
  FROM company_scope

  UNION ALL
  SELECT 20,'retained_received_po',
    CASE WHEN count(*)=1 AND bool_and(
      id='2ea66e69-cd81-4d6c-81ea-e7619112f20b'::uuid
      AND company_id='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid
      AND order_no='PO-20260825-0000000015' AND status='RECEIVED'
      AND private.purchase_supplier_order_net_received_base_qty(company_id,id)=202)
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(
      id='2ea66e69-cd81-4d6c-81ea-e7619112f20b'::uuid
      AND company_id='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid
      AND order_no='PO-20260825-0000000015' AND status='RECEIVED'
      AND private.purchase_supplier_order_net_received_base_qty(company_id,id)=202)
      THEN 0 ELSE GREATEST(count(*),1) END::bigint,
    jsonb_build_object('activeOrders',COALESCE(jsonb_agg(jsonb_build_object(
      'id',id,'orderNo',order_no,'status',status,'companyId',company_id,
      'netReceivedBaseQty',private.purchase_supplier_order_net_received_base_qty(
        company_id,id)) ORDER BY order_no),'[]'::jsonb))
  FROM active_order

  UNION ALL
  SELECT 30,'old_active_procurement_coverage',
    CASE WHEN (SELECT count(*) FROM active_request)=0
        AND NOT EXISTS(SELECT 1 FROM active_order
          WHERE status IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED'))
        AND NOT EXISTS(SELECT 1 FROM public.purchase_daily_batches batch
          WHERE batch.company_id IN(SELECT company_id FROM target_company)
            AND batch.status<>'CANCELED')
      THEN 'PASS' ELSE 'FAIL' END,
    ((SELECT count(*) FROM active_request)+
      (SELECT count(*) FROM active_order
       WHERE status IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED'))+
      (SELECT count(*) FROM public.purchase_daily_batches batch
       WHERE batch.company_id IN(SELECT company_id FROM target_company)
         AND batch.status<>'CANCELED'))::bigint,
    jsonb_build_object(
      'activeStockRequests',(SELECT count(*) FROM active_request),
      'activePoCoverage',(SELECT count(*) FROM active_order
        WHERE status IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED')),
      'activeDailyRo',(SELECT count(*) FROM public.purchase_daily_batches batch
        WHERE batch.company_id IN(SELECT company_id FROM target_company)
          AND batch.status<>'CANCELED'))

  UNION ALL
  SELECT 40,'cleanup_audit_evidence',
    CASE WHEN (SELECT count(*) FROM public.purchase_supplier_order_cancel_operations operation
          WHERE operation.company_id IN(SELECT company_id FROM target_company)
            AND operation.reason='FULL_PROCUREMENT_CLEANUP_20260918')=52
        AND (SELECT count(DISTINCT audit.document_id) FROM public.stock_request_audit audit
          WHERE audit.company_id IN(SELECT company_id FROM target_company)
            AND audit.action='CLOSE'
            AND audit.after_state->>'status'='CLOSED')>=95
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN (SELECT count(*) FROM public.purchase_supplier_order_cancel_operations operation
          WHERE operation.company_id IN(SELECT company_id FROM target_company)
            AND operation.reason='FULL_PROCUREMENT_CLEANUP_20260918')=52
        AND (SELECT count(DISTINCT audit.document_id) FROM public.stock_request_audit audit
          WHERE audit.company_id IN(SELECT company_id FROM target_company)
            AND audit.action='CLOSE'
            AND audit.after_state->>'status'='CLOSED')>=95
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object(
      'poCancelOperations',(SELECT count(*)
        FROM public.purchase_supplier_order_cancel_operations operation
        WHERE operation.company_id IN(SELECT company_id FROM target_company)
          AND operation.reason='FULL_PROCUREMENT_CLEANUP_20260918'),
      'closedRequestAuditTotal',(SELECT count(DISTINCT audit.document_id)
        FROM public.stock_request_audit audit
        WHERE audit.company_id IN(SELECT company_id FROM target_company)
          AND audit.action='CLOSE' AND audit.after_state->>'status'='CLOSED'))

  UNION ALL
  SELECT 50,'next_auto_ro_candidate_parity',
    CASE WHEN count(*) FILTER(WHERE
        COALESCE((candidate->>'openSupplierOrderBaseQty')::numeric,0)<>0
        OR COALESCE((candidate->>'openExactRequestBaseQty')::numeric,0)<>0
        OR COALESCE((candidate->>'ambiguousOpenRequestBaseQty')::numeric,0)<>0
        OR COALESCE((candidate->>'requestedBaseQty')::numeric,0)
          <>-COALESCE((candidate->>'onHandBaseQty')::numeric,0))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE
      COALESCE((candidate->>'openSupplierOrderBaseQty')::numeric,0)<>0
      OR COALESCE((candidate->>'openExactRequestBaseQty')::numeric,0)<>0
      OR COALESCE((candidate->>'ambiguousOpenRequestBaseQty')::numeric,0)<>0
      OR COALESCE((candidate->>'requestedBaseQty')::numeric,0)
        <>-COALESCE((candidate->>'onHandBaseQty')::numeric,0))::bigint,
    jsonb_build_object(
      'negativeOnHandRows',count(*),
      'requestedBaseQty',COALESCE(sum((candidate->>'requestedBaseQty')::numeric),0),
      'rule','With old coverage closed, requested quantity equals current negative On Hand')
  FROM preview_line

  UNION ALL
  SELECT 60,'cleanup_runtime_inventory','INFO',0::bigint,
    jsonb_build_object(
      'canceledPoRows',(SELECT count(*) FROM public.supplier_order_documents document
        WHERE document.company_id IN(SELECT company_id FROM target_company)
          AND document.status='CANCELED'),
      'closedStockRequestRows',(SELECT count(*) FROM public.stock_request_documents document
        WHERE document.company_id IN(SELECT company_id FROM target_company)
          AND document.status='CLOSED'),
      'nextAutomaticDocument','Daily RO; user confirmation creates PO')
)
SELECT check_name,status,violation_rows,details
FROM checks ORDER BY sort_key;
