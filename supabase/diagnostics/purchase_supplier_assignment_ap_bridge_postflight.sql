-- SELECT-only postflight for 20260914130000.
WITH definitions AS (
  SELECT pg_get_functiondef('public.assign_purchase_daily_receipt_suppliers(uuid,bigint,uuid,jsonb)'::regprocedure) assign_def,
    pg_get_functiondef('private.post_purchase_ap_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure) post_def,
    pg_get_functiondef('private.post_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure) dispatcher_def,
    pg_get_functiondef('private.f4b_financial_event_supported(public.financial_events)'::regprocedure) support_def,
    pg_get_functiondef('public.preview_purchase_ap_posting_queue(integer)'::regprocedure) preview_def,
    pg_get_functiondef('private.trg_g5_guard_ap_provisional_lifecycle()'::regprocedure) guard_def
), checks AS (
  SELECT 's6a_migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260914130000'
  UNION ALL
  SELECT 's6a_required_routines',CASE WHEN count(*)=8 THEN 'PASS' ELSE 'FAIL' END,
    abs(8-count(*)),jsonb_build_object('present',count(*),'expected',8)
  FROM unnest(ARRAY[
    to_regprocedure('public.assign_purchase_daily_receipt_suppliers(uuid,bigint,uuid,jsonb)'),
    to_regprocedure('public.assign_purchase_daily_receipt_suppliers_before_step6a(uuid,bigint,uuid,jsonb)'),
    to_regprocedure('private.post_purchase_ap_financial_event_core(uuid,uuid,bigint,uuid)'),
    to_regprocedure('private.purchase_step6a_previous_purchase_ap_event_core(uuid,uuid,bigint,uuid)'),
    to_regprocedure('private.post_financial_event_core(uuid,uuid,bigint,uuid)'),
    to_regprocedure('private.post_financial_event_core_before_purchase_step6a(uuid,uuid,bigint,uuid)'),
    to_regprocedure('private.f4b_financial_event_supported(public.financial_events)'),
    to_regprocedure('private.f4b_financial_event_supported_before_purchase_step6a(public.financial_events)')
  ]) routine WHERE routine IS NOT NULL
  UNION ALL
  SELECT 's6a_call_chain_contract',CASE WHEN position('apProvisionalCount' in assign_def)>0
      AND position('GOODS_RECEIPT_SUPPLIER_ASSIGNMENT' in post_def)>0
      AND position('HOLD_FOR_SUPPLIER_ASSIGNMENT' in post_def)>0
      AND position('purchase_step6a_previous_purchase_ap_event_core' in post_def)>0
      AND position('post_financial_event_core_before_purchase_step6a' in dispatcher_def)>0
      AND position('f4b_financial_event_supported_before_purchase_step6a' in support_def)>0
      AND position('GOODS_RECEIPT_SUPPLIER_ASSIGNMENT' in preview_def)>0
      AND position('HOLD_FOR_STEP_6_RECLASSIFICATION' in preview_def)=0
      AND position('goods_receipt_supplier_assignments' in guard_def)>0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('apProvisionalCount' in assign_def)>0
      AND position('GOODS_RECEIPT_SUPPLIER_ASSIGNMENT' in post_def)>0
      AND position('HOLD_FOR_SUPPLIER_ASSIGNMENT' in post_def)>0
      AND position('purchase_step6a_previous_purchase_ap_event_core' in post_def)>0
      AND position('post_financial_event_core_before_purchase_step6a' in dispatcher_def)>0
      AND position('f4b_financial_event_supported_before_purchase_step6a' in support_def)>0
      AND position('GOODS_RECEIPT_SUPPLIER_ASSIGNMENT' in preview_def)>0
      AND position('HOLD_FOR_STEP_6_RECLASSIFICATION' in preview_def)=0
      AND position('goods_receipt_supplier_assignments' in guard_def)>0
      THEN 0 ELSE 1 END,jsonb_build_object('assignmentBridge',position('apProvisionalCount' in assign_def)>0,
        'receiptToClearingBridge',position('HOLD_FOR_SUPPLIER_ASSIGNMENT' in post_def)>0,
        'assignmentToApBridge',position('GOODS_RECEIPT_SUPPLIER_ASSIGNMENT' in post_def)>0,
        'dispatcherBridge',position('post_financial_event_core_before_purchase_step6a' in dispatcher_def)>0,
        'genericQueueSupport',position('f4b_financial_event_supported_before_purchase_step6a' in support_def)>0,
        'purchaseQueueSupport',position('GOODS_RECEIPT_SUPPLIER_ASSIGNMENT' in preview_def)>0)
  FROM definitions
  UNION ALL
  SELECT 's6a_ap_assignment_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.goods_receipt_supplier_assignments assignment
  LEFT JOIN public.goods_receipt_ap_provisionals provisional
    ON provisional.company_id=assignment.company_id
   AND provisional.receipt_line_id=assignment.receipt_line_id
  WHERE provisional.id IS NULL OR provisional.receipt_id<>assignment.receipt_id
    OR provisional.supplier_id<>assignment.supplier_id
    OR provisional.amount<>assignment.assigned_amount
  UNION ALL
  SELECT 's6a_assignment_event_source_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.financial_events event
  LEFT JOIN public.goods_receipt_supplier_assignment_operations operation
    ON operation.company_id=event.company_id AND operation.id=event.source_id
   AND operation.financial_event_id=event.id
  LEFT JOIN public.goods_receipt_supplier_assignments assignment
    ON assignment.company_id=operation.company_id AND assignment.operation_id=operation.id
  LEFT JOIN public.goods_receipt_unassigned_clearings clearing
    ON clearing.company_id=assignment.company_id AND clearing.id=assignment.clearing_id
  WHERE event.system_event_key='GOODS_RECEIPT_SUPPLIER_ASSIGNMENT'
    AND (event.source_table<>'goods_receipt_supplier_assignment_operations'
      OR operation.id IS NULL OR assignment.id IS NULL OR clearing.id IS NULL
      OR NULLIF(event.amounts->>'unassignedSupplierClearingAccountId','')::uuid
        IS DISTINCT FROM clearing.clearing_account_id)
  UNION ALL
  SELECT 's6a_pending_receipt_source_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM public.financial_events event
  LEFT JOIN public.goods_receipt_documents receipt
    ON receipt.company_id=event.company_id AND receipt.id=event.source_id
   AND receipt.financial_event_id=event.id
  WHERE event.system_event_key='GOODS_RECEIPT'
    AND event.amounts->>'financePostingState'='HOLD_FOR_SUPPLIER_ASSIGNMENT'
    AND (event.source_table<>'goods_receipt_documents' OR receipt.id IS NULL
      OR receipt.status<>'POSTED' OR receipt.receipt_scope<>'DAILY_WAREHOUSE'
      OR receipt.supplier_assignment_status<>'SUPPLIER_PENDING'
      OR EXISTS(SELECT 1 FROM public.goods_receipt_unassigned_clearings clearing
        WHERE clearing.company_id=receipt.company_id AND clearing.receipt_id=receipt.id
          AND clearing.clearing_account_id IS DISTINCT FROM
            NULLIF(event.amounts->>'unassignedSupplierClearingAccountId','')::uuid))
  UNION ALL
  SELECT 's6a_journal_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.financial_events event
  LEFT JOIN public.finance_journals journal
    ON journal.company_id=event.company_id AND journal.financial_event_id=event.id
   AND journal.status='POSTED'
  WHERE event.system_event_key='GOODS_RECEIPT_SUPPLIER_ASSIGNMENT'
    AND ((event.status='POSTED'::public.event_status AND journal.id IS NULL)
      OR (event.status='CANCELED'::public.event_status
        AND (event.error_message<>'NO_FINANCIAL_EFFECT' OR journal.id IS NOT NULL)))
  UNION ALL
  SELECT 's6a_assignment_journal_amount_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM public.financial_events event
  JOIN public.finance_journals journal
    ON journal.company_id=event.company_id AND journal.financial_event_id=event.id
   AND journal.status='POSTED'
  WHERE event.system_event_key='GOODS_RECEIPT_SUPPLIER_ASSIGNMENT'
    AND event.status='POSTED'::public.event_status
    AND (round(journal.total_debit,4)<>
        round((event.amounts->>'unassignedSupplierClearingDebit')::numeric,4)
      OR round(journal.total_credit,4)<>
        round((event.amounts->>'supplierApProvisionalCredit')::numeric,4)
      OR round(COALESCE((SELECT sum(line.debit)
          FROM public.finance_journal_lines line
          JOIN public.chart_of_accounts account
            ON account.company_id=line.company_id AND account.id=line.account_id
          WHERE line.company_id=journal.company_id AND line.journal_id=journal.id
            AND account.system_function_key='PURCHASE_UNASSIGNED_CLEARING'),0),4)
        <>round((event.amounts->>'unassignedSupplierClearingDebit')::numeric,4)
      OR round(COALESCE((SELECT sum(line.credit)
          FROM public.finance_journal_lines line
          JOIN public.chart_of_accounts account
            ON account.company_id=line.company_id AND account.id=line.account_id
          WHERE line.company_id=journal.company_id AND line.journal_id=journal.id
            AND account.system_function_key='SUPPLIER_AP_PROVISIONAL'),0),4)
        <>round((event.amounts->>'supplierApProvisionalCredit')::numeric,4))
  UNION ALL
  SELECT 's6a_pending_receipt_journal_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM public.financial_events event
  LEFT JOIN public.finance_journals journal
    ON journal.company_id=event.company_id AND journal.financial_event_id=event.id
   AND journal.status='POSTED'
  WHERE event.system_event_key='GOODS_RECEIPT'
    AND event.amounts->>'financePostingState'='HOLD_FOR_SUPPLIER_ASSIGNMENT'
    AND ((event.status='POSTED'::public.event_status AND journal.id IS NULL)
      OR (event.status='CANCELED'::public.event_status
        AND (event.error_message<>'NO_FINANCIAL_EFFECT' OR journal.id IS NOT NULL)))
  UNION ALL
  SELECT 's6a_pending_receipt_journal_amount_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM public.financial_events event
  JOIN public.finance_journals journal
    ON journal.company_id=event.company_id AND journal.financial_event_id=event.id
   AND journal.status='POSTED'
  WHERE event.system_event_key='GOODS_RECEIPT'
    AND event.amounts->>'financePostingState'='HOLD_FOR_SUPPLIER_ASSIGNMENT'
    AND event.status='POSTED'::public.event_status
    AND (round(journal.total_debit,4)<>round((event.amounts->>'inventoryDebit')::numeric,4)
      OR round(journal.total_credit,4)<>
        round((event.amounts->>'unassignedSupplierClearingCredit')::numeric,4)
      OR round(COALESCE((SELECT sum(line.debit)
          FROM public.finance_journal_lines line
          JOIN public.chart_of_accounts account
            ON account.company_id=line.company_id AND account.id=line.account_id
          WHERE line.company_id=journal.company_id AND line.journal_id=journal.id
            AND account.system_function_key='INVENTORY_ASSET'),0),4)
        <>round((event.amounts->>'inventoryDebit')::numeric,4)
      OR round(COALESCE((SELECT sum(line.credit)
          FROM public.finance_journal_lines line
          JOIN public.chart_of_accounts account
            ON account.company_id=line.company_id AND account.id=line.account_id
          WHERE line.company_id=journal.company_id AND line.journal_id=journal.id
            AND account.system_function_key='PURCHASE_UNASSIGNED_CLEARING'),0),4)
        <>round((event.amounts->>'unassignedSupplierClearingCredit')::numeric,4))
  UNION ALL
  SELECT 's6a_posting_sequence_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('assignmentPostedBeforeReceipt',count(*))
  FROM public.goods_receipt_supplier_assignment_operations operation
  JOIN public.financial_events assignment_event
    ON assignment_event.company_id=operation.company_id
   AND assignment_event.id=operation.financial_event_id
  JOIN public.goods_receipt_documents receipt
    ON receipt.company_id=operation.company_id AND receipt.id=operation.receipt_id
  LEFT JOIN public.financial_events receipt_event
    ON receipt_event.company_id=receipt.company_id AND receipt_event.id=receipt.financial_event_id
  WHERE assignment_event.status IN(
      'POSTED'::public.event_status,'CANCELED'::public.event_status)
    AND (receipt_event.id IS NULL OR receipt_event.status NOT IN(
      'POSTED'::public.event_status,'CANCELED'::public.event_status))
  UNION ALL
  SELECT 's6a_private_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='private' AND privilege.grantee='authenticated'
    AND privilege.routine_name IN('post_purchase_ap_financial_event_core',
      'purchase_step6a_previous_purchase_ap_event_core',
      'post_financial_event_core_before_purchase_step6a',
      'f4b_financial_event_supported_before_purchase_step6a')
  UNION ALL
  SELECT 's6a_runtime_inventory','INFO',0,jsonb_build_object(
    'assignmentLines',(SELECT count(*) FROM public.goods_receipt_supplier_assignments),
    'openAssignmentEvents',(SELECT count(*) FROM public.financial_events event
      WHERE event.system_event_key='GOODS_RECEIPT_SUPPLIER_ASSIGNMENT'
        AND event.status='HOLD'::public.event_status),
    'postedAssignmentEvents',(SELECT count(*) FROM public.financial_events event
      WHERE event.system_event_key='GOODS_RECEIPT_SUPPLIER_ASSIGNMENT'
        AND event.status='POSTED'::public.event_status),
    'openPendingSupplierReceiptEvents',(SELECT count(*) FROM public.financial_events event
      WHERE event.system_event_key='GOODS_RECEIPT'
        AND event.amounts->>'financePostingState'='HOLD_FOR_SUPPLIER_ASSIGNMENT'
        AND event.status='HOLD'::public.event_status))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
