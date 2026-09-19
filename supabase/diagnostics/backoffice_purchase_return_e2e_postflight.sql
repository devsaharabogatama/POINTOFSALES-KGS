-- Read-only verification after 20260919140000, 20260919141000, 20260919142000.
WITH required_migrations(version) AS (
  VALUES ('20260919140000'),('20260919141000'),('20260919142000')
), required_relations(name) AS (
  VALUES ('purchase_return_draft_operations'),
    ('purchase_return_finance_allocations'),('supplier_return_credit_notes')
), required_routines(signature) AS (
  VALUES ('public.get_backoffice_purchase_return_workspace(uuid)'),
    ('public.save_backoffice_purchase_return_draft(uuid,bigint,uuid,uuid,uuid,date,text,text,text,jsonb)'),
    ('public.post_backoffice_purchase_return(uuid,bigint,uuid)'),
    ('public.get_backoffice_purchase_return_finance()'),
    ('public.get_purchase_supplier_order_return_readiness(uuid)'),
    ('public.cancel_purchase_supplier_order(uuid,bigint,uuid,text)'),
    ('private.purchase_supplier_order_return_readiness_core(uuid,uuid)')
), ledger_check AS (
  SELECT array_agg(required.version ORDER BY required.version)
    FILTER(WHERE installed.version IS NULL) missing
  FROM required_migrations required
  LEFT JOIN private.kgs_schema_migrations installed USING(version)
), relation_check AS (
  SELECT array_agg(required.name ORDER BY required.name)
    FILTER(WHERE to_regclass('public.'||required.name) IS NULL) missing
  FROM required_relations required
), routine_check AS (
  SELECT array_agg(required.signature ORDER BY required.signature)
    FILTER(WHERE to_regprocedure(required.signature) IS NULL) missing
  FROM required_routines required
), supplier_payment_runtime AS (
  SELECT regexp_replace(lower(pg_get_functiondef(
      'public.save_supplier_payment_draft(uuid,bigint,uuid,date,text,uuid,text,text,text,text,text,text,jsonb)'::regprocedure)),
      '\s+','','g') save_body,
    regexp_replace(lower(pg_get_functiondef(
      'public.get_finance_supplier_payments()'::regprocedure)),'\s+','','g') read_body,
    regexp_replace(lower(pg_get_functiondef(
      'public.validate_supplier_payment(uuid,bigint,uuid)'::regprocedure)),
      '\s+','','g') validate_body
), posted_backoffice AS (
  SELECT document.* FROM public.purchase_return_documents document
  WHERE document.source_channel='BACKOFFICE' AND document.status='POSTED'
), checks AS (
  SELECT 'backoffice_purchase_return_migration_ledger' check_name,
    CASE WHEN COALESCE(cardinality(missing),0)=0 THEN 'PASS' ELSE 'FAIL' END status,
    COALESCE(cardinality(missing),0)::bigint violation_rows,
    jsonb_build_object('missing',COALESCE(to_jsonb(missing),'[]'::jsonb),'expected',3) details
  FROM ledger_check
  UNION ALL
  SELECT 'backoffice_purchase_return_relation_contract',
    CASE WHEN COALESCE(cardinality(missing),0)=0 THEN 'PASS' ELSE 'FAIL' END,
    COALESCE(cardinality(missing),0)::bigint,
    jsonb_build_object('missing',COALESCE(to_jsonb(missing),'[]'::jsonb),'expected',3)
  FROM relation_check
  UNION ALL
  SELECT 'backoffice_purchase_return_routine_contract',
    CASE WHEN COALESCE(cardinality(missing),0)=0 THEN 'PASS' ELSE 'FAIL' END,
    COALESCE(cardinality(missing),0)::bigint,
    jsonb_build_object('missing',COALESCE(to_jsonb(missing),'[]'::jsonb),'expected',7)
  FROM routine_check
  UNION ALL
  SELECT 'backoffice_purchase_return_supplier_payment_net_balance',
    CASE WHEN position('supplier_payment_exceeds_net_invoice_balance' IN save_body)>0
      AND position('supplier_payment_exceeds_net_invoice_balance' IN validate_body)>0
      AND position('supplier_credit_amount' IN read_body)>0
      AND position('ap_final_reduction' IN read_body)>0 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('supplier_payment_exceeds_net_invoice_balance' IN save_body)>0
      AND position('supplier_payment_exceeds_net_invoice_balance' IN validate_body)>0
      AND position('supplier_credit_amount' IN read_body)>0
      AND position('ap_final_reduction' IN read_body)>0 THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('netPaymentGuard',
      position('supplier_payment_exceeds_net_invoice_balance' IN save_body)>0,
      'validationRecheck',
      position('supplier_payment_exceeds_net_invoice_balance' IN validate_body)>0,
      'netBalanceReadModel',position('supplier_credit_amount' IN read_body)>0)
  FROM supplier_payment_runtime
  UNION ALL
  SELECT 'backoffice_purchase_return_source_channel_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.purchase_return_documents document
  WHERE (document.source_channel='POS' AND
      (document.created_session_id IS NULL OR document.created_pos_id IS NULL))
    OR (document.source_channel='BACKOFFICE' AND
      (document.created_session_id IS NOT NULL OR document.created_pos_id IS NOT NULL))
    OR document.source_channel NOT IN('POS','BACKOFFICE')
  UNION ALL
  SELECT 'backoffice_purchase_return_active_draft_uniqueness',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('duplicateGroups',count(*))
  FROM (SELECT company_id,source_receipt_id,source_warehouse_id
    FROM public.purchase_return_documents WHERE status='DRAFT'
    GROUP BY company_id,source_receipt_id,source_warehouse_id HAVING count(*)>1) duplicate
  UNION ALL
  SELECT 'backoffice_purchase_return_line_finance_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidLines',count(*))
  FROM public.purchase_return_lines line
  JOIN posted_backoffice document ON document.company_id=line.company_id
    AND document.id=line.document_id
  LEFT JOIN LATERAL(SELECT sum(allocation.quantity_base) quantity_base,
      sum(allocation.provisional_value) provisional_value
    FROM public.purchase_return_finance_allocations allocation
    WHERE allocation.company_id=line.company_id AND allocation.return_line_id=line.id) finance ON TRUE
  WHERE round(COALESCE(finance.quantity_base,0),6)<>round(line.return_base_qty,6)
    OR round(COALESCE(finance.provisional_value,0),4)
      <>round(line.provisional_return_value,4)
  UNION ALL
  SELECT 'backoffice_purchase_return_stock_fifo_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidLines',count(*))
  FROM public.purchase_return_lines line
  JOIN posted_backoffice document ON document.company_id=line.company_id
    AND document.id=line.document_id
  WHERE NOT EXISTS(SELECT 1 FROM public.purchase_return_fifo_allocations fifo
      JOIN public.stock_movements movement ON movement.company_id=fifo.company_id
        AND movement.reference_table='purchase_return_documents'
        AND movement.reference_id=fifo.document_id AND movement.source_line_id=fifo.id
        AND movement.movement_type='PURCHASE_RETURN'
        AND movement.qty_change=-fifo.quantity_base
      WHERE fifo.company_id=line.company_id AND fifo.return_line_id=line.id
        AND fifo.quantity_base=line.return_base_qty)
  UNION ALL
  SELECT 'backoffice_purchase_return_finance_event_journal',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidDocuments',count(*))
  FROM posted_backoffice document
  LEFT JOIN public.financial_events event ON event.company_id=document.company_id
    AND event.id=document.financial_event_id
  LEFT JOIN public.finance_journals journal ON journal.company_id=event.company_id
    AND journal.financial_event_id=event.id
  WHERE event.id IS NULL OR event.status<>'POSTED'::public.event_status
    OR event.system_event_key<>'PURCHASE_RETURN'
    OR journal.id IS NULL OR journal.status<>'POSTED'
    OR round(journal.total_debit,4)<>round(journal.total_credit,4)
  UNION ALL
  SELECT 'backoffice_purchase_return_supplier_credit_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidDocuments',count(*))
  FROM posted_backoffice document
  LEFT JOIN LATERAL(SELECT
      sum(allocation.actual_value) actual_value,
      sum(allocation.recoverable_tax_value) recoverable_tax,
      sum(allocation.nonrecoverable_tax_value) nonrecoverable_tax,
      sum(allocation.ap_final_reduction) ap_final,
      sum(allocation.supplier_refund_receivable) refund
    FROM public.purchase_return_finance_allocations allocation
    WHERE allocation.company_id=document.company_id
      AND allocation.document_id=document.id
      AND allocation.allocation_kind='INVOICED') finance ON TRUE
  LEFT JOIN public.supplier_return_credit_notes note
    ON note.company_id=document.company_id AND note.purchase_return_id=document.id
  WHERE (COALESCE(finance.actual_value,0)+COALESCE(finance.recoverable_tax,0)
      +COALESCE(finance.nonrecoverable_tax,0)>0 AND note.id IS NULL)
    OR (note.id IS NOT NULL AND (
      round(note.actual_value,4)<>round(COALESCE(finance.actual_value,0),4)
      OR round(note.recoverable_tax_value,4)<>round(COALESCE(finance.recoverable_tax,0),4)
      OR round(note.nonrecoverable_tax_value,4)<>round(COALESCE(finance.nonrecoverable_tax,0),4)
      OR round(note.ap_final_reduction,4)<>round(COALESCE(finance.ap_final,0),4)
      OR round(note.supplier_refund_receivable,4)<>round(COALESCE(finance.refund,0),4)))
  UNION ALL
  SELECT 'backoffice_purchase_return_retail_compatibility',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidPosRows',count(*),'rule','POS Returns keep Session/POS ownership and existing public RPC')
  FROM public.purchase_return_documents document
  WHERE document.source_channel='POS'
    AND (document.created_session_id IS NULL OR document.created_pos_id IS NULL)
  UNION ALL
  SELECT 'backoffice_purchase_return_permission_contract',
    CASE WHEN has_function_privilege('authenticated',
        'public.save_backoffice_purchase_return_draft(uuid,bigint,uuid,uuid,uuid,date,text,text,text,jsonb)','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.post_backoffice_purchase_return(uuid,bigint,uuid)','EXECUTE')
      AND NOT has_table_privilege('authenticated',
        'public.purchase_return_finance_allocations','INSERT,UPDATE,DELETE')
      AND NOT has_table_privilege('authenticated',
        'public.supplier_return_credit_notes','INSERT,UPDATE,DELETE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN has_function_privilege('authenticated',
        'public.save_backoffice_purchase_return_draft(uuid,bigint,uuid,uuid,uuid,date,text,text,text,jsonb)','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.post_backoffice_purchase_return(uuid,bigint,uuid)','EXECUTE')
      AND NOT has_table_privilege('authenticated',
        'public.purchase_return_finance_allocations','INSERT,UPDATE,DELETE')
      AND NOT has_table_privilege('authenticated',
        'public.supplier_return_credit_notes','INSERT,UPDATE,DELETE')
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('authenticatedRpc',true,'authenticatedDirectFinanceWrite',false)
  UNION ALL
  SELECT 'backoffice_purchase_return_runtime_inventory','INFO',0,
    jsonb_build_object('drafts',count(*) FILTER(WHERE status='DRAFT'),
      'posted',count(*) FILTER(WHERE status='POSTED'),
      'canceled',count(*) FILTER(WHERE status='CANCELED'),
      'postedBaseQty',COALESCE(sum(total_return_base_qty) FILTER(WHERE status='POSTED'),0))
  FROM public.purchase_return_documents WHERE source_channel='BACKOFFICE'
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
