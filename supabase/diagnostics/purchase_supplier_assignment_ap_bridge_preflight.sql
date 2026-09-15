-- SELECT-only preflight for Purchase Daily Replenishment Step 6/6A.
WITH dependency AS (
  SELECT required_version,EXISTS(SELECT 1 FROM private.kgs_schema_migrations migration
    WHERE migration.version=required_version) present
  FROM unnest(ARRAY['20260914100000','20260914112000']) required_version
), routine_fact AS (
  SELECT to_regprocedure('public.assign_purchase_daily_receipt_suppliers(uuid,bigint,uuid,jsonb)') assign_rpc,
    to_regprocedure('private.post_purchase_ap_financial_event_core(uuid,uuid,bigint,uuid)') post_core,
    to_regprocedure('private.post_financial_event_core(uuid,uuid,bigint,uuid)') dispatcher,
    to_regprocedure('private.f4b_financial_event_supported(public.financial_events)') supported,
    to_regprocedure('public.preview_purchase_ap_posting_queue(integer)') preview_rpc
), definition_fact AS (
  SELECT pg_get_functiondef(assign_rpc) assign_definition,
    pg_get_functiondef(post_core) post_definition,
    pg_get_functiondef(dispatcher) dispatcher_definition,
    pg_get_functiondef(preview_rpc) preview_definition FROM routine_fact
), checks AS (
  SELECT 's6a_dependency_ledger' check_name,
    CASE WHEN count(*) FILTER(WHERE present)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    2-count(*) FILTER(WHERE present) violation_rows,
    jsonb_build_object('present',COALESCE(jsonb_agg(required_version) FILTER(WHERE present),'[]'::jsonb),
      'expected',2) details FROM dependency
  UNION ALL
  SELECT 's6a_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 's6a_required_runtime',CASE WHEN assign_rpc IS NOT NULL AND post_core IS NOT NULL
      AND dispatcher IS NOT NULL AND supported IS NOT NULL AND preview_rpc IS NOT NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN assign_rpc IS NOT NULL AND post_core IS NOT NULL AND dispatcher IS NOT NULL
      AND supported IS NOT NULL AND preview_rpc IS NOT NULL THEN 0 ELSE 1 END,
    jsonb_build_object('assign',assign_rpc IS NOT NULL,'postCore',post_core IS NOT NULL,
      'dispatcher',dispatcher IS NOT NULL,'supported',supported IS NOT NULL,
      'purchasePreview',preview_rpc IS NOT NULL) FROM routine_fact
  UNION ALL
  SELECT 's6a_call_chain_contract',CASE WHEN position('HOLD_FOR_STEP_6_RECLASSIFICATION' in assign_definition)>0
      AND position('goods_receipt_supplier_assignments' in assign_definition)>0
      AND position('nsc_previous_purchase_ap_financial_event_core' in post_definition)>0
      AND position('post_financial_event_core_pre_backoffice_discrepancy_stock_loss' in dispatcher_definition)>0
      AND position('HOLD_FOR_STEP_6_RECLASSIFICATION' in preview_definition)>0
      AND position('GOODS_RECEIPT_SUPPLIER_ASSIGNMENT' in preview_definition)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN position('HOLD_FOR_STEP_6_RECLASSIFICATION' in assign_definition)>0
      AND position('goods_receipt_supplier_assignments' in assign_definition)>0
      AND position('nsc_previous_purchase_ap_financial_event_core' in post_definition)>0
      AND position('post_financial_event_core_pre_backoffice_discrepancy_stock_loss' in dispatcher_definition)>0
      AND position('HOLD_FOR_STEP_6_RECLASSIFICATION' in preview_definition)>0
      AND position('GOODS_RECEIPT_SUPPLIER_ASSIGNMENT' in preview_definition)=0
      THEN 0 ELSE 1 END,
    jsonb_build_object('assignmentStep5',position('HOLD_FOR_STEP_6_RECLASSIFICATION' in assign_definition)>0,
      'nscPurchaseCore',position('nsc_previous_purchase_ap_financial_event_core' in post_definition)>0,
      'latestDispatcher',position('post_financial_event_core_pre_backoffice_discrepancy_stock_loss' in dispatcher_definition)>0,
      'assignmentStillExcluded',position('HOLD_FOR_STEP_6_RECLASSIFICATION' in preview_definition)>0)
  FROM definition_fact
  UNION ALL
  SELECT 's6a_assignment_lineage',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.goods_receipt_supplier_assignments assignment
  JOIN public.goods_receipt_unassigned_clearings clearing
    ON clearing.company_id=assignment.company_id AND clearing.id=assignment.clearing_id
  JOIN public.goods_receipt_supplier_assignment_operations operation
    ON operation.company_id=assignment.company_id AND operation.id=assignment.operation_id
  LEFT JOIN public.financial_events event
    ON event.company_id=operation.company_id AND event.id=operation.financial_event_id
  WHERE assignment.receipt_id<>clearing.receipt_id
    OR assignment.receipt_line_id<>clearing.receipt_line_id
    OR assignment.assigned_amount<>clearing.amount
    OR operation.receipt_id<>assignment.receipt_id OR event.id IS NULL
    OR event.system_event_key<>'GOODS_RECEIPT_SUPPLIER_ASSIGNMENT'
    OR event.source_table<>'goods_receipt_supplier_assignment_operations'
    OR event.source_id<>operation.id
    OR event.status<>'HOLD'::public.event_status
    OR event.amounts->>'financePostingState'<>'HOLD_FOR_STEP_6_RECLASSIFICATION'
    OR NULLIF(event.amounts->>'unassignedSupplierClearingAccountId','')::uuid
      IS DISTINCT FROM clearing.clearing_account_id
  UNION ALL
  SELECT 's6a_pending_receipt_lineage',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.goods_receipt_documents receipt
  LEFT JOIN public.financial_events event
    ON event.company_id=receipt.company_id AND event.id=receipt.financial_event_id
  WHERE receipt.status='POSTED' AND receipt.receipt_scope='DAILY_WAREHOUSE'
    AND receipt.supplier_assignment_status='SUPPLIER_PENDING'
    AND (event.id IS NULL OR event.system_event_key<>'GOODS_RECEIPT'
      OR event.event_type::text<>'PURCHASE_POSTED'
      OR event.source_table<>'goods_receipt_documents' OR event.source_id<>receipt.id
      OR event.status<>'HOLD'::public.event_status
      OR event.amounts->>'financePostingState'<>'HOLD_FOR_SUPPLIER_ASSIGNMENT'
      OR round(COALESCE((event.amounts->>'inventoryDebit')::numeric,-1),4)
        <>round(receipt.provisional_ap_total,4)
      OR round(COALESCE((event.amounts->>'unassignedSupplierClearingCredit')::numeric,-1),4)
        <>round(receipt.provisional_ap_total,4)
      OR EXISTS(SELECT 1 FROM public.goods_receipt_unassigned_clearings clearing
        WHERE clearing.company_id=receipt.company_id AND clearing.receipt_id=receipt.id
          AND clearing.clearing_account_id IS DISTINCT FROM
            NULLIF(event.amounts->>'unassignedSupplierClearingAccountId','')::uuid))
  UNION ALL
  SELECT 's6a_existing_ap_conflict',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('conflictRows',count(*))
  FROM public.goods_receipt_supplier_assignments assignment
  JOIN public.goods_receipt_ap_provisionals provisional
    ON provisional.company_id=assignment.company_id
   AND provisional.receipt_line_id=assignment.receipt_line_id
  WHERE provisional.receipt_id<>assignment.receipt_id
    OR provisional.supplier_id<>assignment.supplier_id
    OR provisional.amount<>assignment.assigned_amount
  UNION ALL
  SELECT 's6a_behavior_fixture_company',CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)>0 THEN 0 ELSE 1 END,
    jsonb_build_object('eligibleCompanies',count(*),'requires','Active Step-1 Company with current open period')
  FROM public.companies company
  JOIN public.company_purchase_replenishment_settings setting ON setting.company_id=company.id
  WHERE company.status='ACTIVE' AND EXISTS(SELECT 1 FROM public.accounting_periods period
    WHERE period.company_id=company.id AND period.status IN('OPEN','REOPENED')
      AND (clock_timestamp() AT TIME ZONE company.timezone)::date
        BETWEEN period.start_date AND period.end_date)
  UNION ALL
  SELECT 's6a_runtime_inventory','INFO',0,jsonb_build_object(
    'assignmentLines',(SELECT count(*) FROM public.goods_receipt_supplier_assignments),
    'missingApProvisionals',(SELECT count(*) FROM public.goods_receipt_supplier_assignments assignment
      LEFT JOIN public.goods_receipt_ap_provisionals provisional
        ON provisional.company_id=assignment.company_id
       AND provisional.receipt_line_id=assignment.receipt_line_id WHERE provisional.id IS NULL),
    'assignmentHoldEvents',(SELECT count(*) FROM public.financial_events event
      WHERE event.system_event_key='GOODS_RECEIPT_SUPPLIER_ASSIGNMENT'
        AND event.status='HOLD'::public.event_status),
    'pendingSupplierReceiptEvents',(SELECT count(*) FROM public.financial_events event
      WHERE event.system_event_key='GOODS_RECEIPT'
        AND event.amounts->>'financePostingState'='HOLD_FOR_SUPPLIER_ASSIGNMENT'
        AND event.status='HOLD'::public.event_status))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
