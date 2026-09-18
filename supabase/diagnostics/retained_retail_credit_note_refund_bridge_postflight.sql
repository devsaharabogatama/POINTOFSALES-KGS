-- SELECT-only closing verification for 20260918150000.
WITH invalid_notes AS (
  SELECT note.id FROM public.backoffice_sales_credit_notes note
  WHERE NOT ((note.source_kind='BACKOFFICE' AND note.source_invoice_id IS NOT NULL
      AND note.source_retail_sales_id IS NULL AND note.source_retail_invoice_snapshot_id IS NULL)
    OR (note.source_kind='RETAINED_RETAIL' AND note.source_invoice_id IS NULL
      AND note.source_retail_sales_id IS NOT NULL
      AND note.source_retail_invoice_snapshot_id IS NOT NULL))
),invalid_lines AS (
  SELECT line.id FROM public.backoffice_sales_credit_note_lines line
  WHERE NOT ((line.source_kind='BACKOFFICE' AND line.sales_order_line_id IS NOT NULL
      AND line.source_invoice_line_id IS NOT NULL AND line.source_retail_sales_detail_id IS NULL)
    OR (line.source_kind='RETAINED_RETAIL' AND line.sales_order_line_id IS NULL
      AND line.source_invoice_line_id IS NULL AND line.source_retail_sales_detail_id IS NOT NULL))
),invalid_finance AS (
  SELECT note.id FROM public.backoffice_sales_credit_notes note
  LEFT JOIN public.finance_journals journal ON journal.company_id=note.company_id
    AND journal.financial_event_id=note.financial_event_id AND journal.status='POSTED'
  WHERE note.source_kind='RETAINED_RETAIL' AND note.status='POSTED'
    AND (journal.id IS NULL OR journal.total_debit<>note.grand_total
      OR journal.total_credit<>note.grand_total
      OR note.ar_reduction_amount+note.refund_liability_amount<>note.grand_total)
),invalid_allocations AS (
  SELECT allocation.id FROM public.backoffice_sales_return_invoice_allocations allocation
  JOIN public.backoffice_sales_returns document ON document.company_id=allocation.company_id
    AND document.id=allocation.return_id
  WHERE document.source_kind='RETAINED_RETAIL'
    AND (allocation.source_kind<>'RETAINED_RETAIL'
      OR allocation.allocation_type<>'RETAIL_POSTED_INVOICE'
      OR allocation.source_retail_sales_id<>document.retail_sales_id
      OR allocation.source_retail_sales_detail_id IS NULL
      OR allocation.credit_note_id IS NULL)
),invalid_refunds AS (
  SELECT refund.id FROM public.backoffice_sales_customer_refunds refund
  JOIN public.backoffice_sales_credit_notes note ON note.company_id=refund.company_id
    AND note.id=refund.credit_note_id
  WHERE refund.source_kind<>note.source_kind
    OR refund.source_invoice_id IS DISTINCT FROM note.source_invoice_id
    OR refund.source_retail_sales_id IS DISTINCT FROM note.source_retail_sales_id
)
SELECT * FROM (
  SELECT 'retained_credit_migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260918150000'
  UNION ALL
  SELECT 'retained_credit_required_routines',
    CASE WHEN count(*)=9 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-9)::bigint,
    jsonb_build_object('present',count(*),'expected',9)
  FROM (VALUES
    ('private.allocate_backoffice_sales_return_invoices_before_retained(uuid,bigint,uuid,jsonb)'),
    ('private.allocate_retained_retail_return_credit_core(uuid,bigint,uuid,jsonb)'),
    ('public.allocate_backoffice_sales_return_invoices(uuid,bigint,uuid,jsonb)'),
    ('private.post_backoffice_sales_credit_note_before_retained(uuid,bigint,uuid)'),
    ('private.post_retained_retail_credit_note_core(uuid,bigint,uuid)'),
    ('private.trg_assign_backoffice_customer_refund_source()'),
    ('public.post_backoffice_sales_credit_note(uuid,bigint,uuid)'),
    ('public.get_retained_retail_return_invoice_workspace(uuid)'),
    ('public.get_backoffice_sales_credit_note_payment_context(uuid)')) item(signature)
  WHERE to_regprocedure(signature) IS NOT NULL
  UNION ALL
  SELECT 'retained_credit_source_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidNotes',count(*)) FROM invalid_notes
  UNION ALL
  SELECT 'retained_credit_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidLines',count(*)) FROM invalid_lines
  UNION ALL
  SELECT 'retained_credit_allocation_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidAllocations',count(*)) FROM invalid_allocations
  UNION ALL
  SELECT 'retained_credit_finance_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidPostedNotes',count(*)) FROM invalid_finance
  UNION ALL
  SELECT 'retained_credit_refund_source_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRefunds',count(*)) FROM invalid_refunds
  UNION ALL
  SELECT 'retained_credit_refund_trigger_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-1)::bigint,
    jsonb_build_object('triggerRows',count(*))
  FROM pg_trigger trigger
  WHERE trigger.tgrelid='public.backoffice_sales_customer_refunds'::regclass
    AND trigger.tgname='assign_backoffice_customer_refund_source'
    AND NOT trigger.tgisinternal AND trigger.tgenabled IN('O','A')
  UNION ALL
  SELECT 'retained_credit_fee_trigger_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-1)::bigint,
    jsonb_build_object('triggerRows',count(*))
  FROM pg_trigger trigger
  WHERE trigger.tgrelid='public.backoffice_sales_credit_notes'::regclass
    AND trigger.tgname='retained_retail_credit_note_fee_guard'
    AND NOT trigger.tgisinternal AND trigger.tgenabled IN('O','A')
  UNION ALL
  SELECT 'retained_credit_dispatch_contract',
    CASE WHEN position('private.allocate_backoffice_sales_return_invoices_before_retained' IN
          pg_get_functiondef(to_regprocedure(
            'public.allocate_backoffice_sales_return_invoices(uuid,bigint,uuid,jsonb)')))>0
        AND position('private.post_backoffice_sales_credit_note_before_retained' IN
          pg_get_functiondef(to_regprocedure(
            'public.post_backoffice_sales_credit_note(uuid,bigint,uuid)')))>0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('private.allocate_backoffice_sales_return_invoices_before_retained' IN
          pg_get_functiondef(to_regprocedure(
            'public.allocate_backoffice_sales_return_invoices(uuid,bigint,uuid,jsonb)')))>0
        AND position('private.post_backoffice_sales_credit_note_before_retained' IN
          pg_get_functiondef(to_regprocedure(
            'public.post_backoffice_sales_credit_note(uuid,bigint,uuid)')))>0
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('nativeAllocatorDelegated',position(
      'private.allocate_backoffice_sales_return_invoices_before_retained' IN
      pg_get_functiondef(to_regprocedure(
        'public.allocate_backoffice_sales_return_invoices(uuid,bigint,uuid,jsonb)')))>0,
      'nativePostingDelegated',position(
      'private.post_backoffice_sales_credit_note_before_retained' IN
      pg_get_functiondef(to_regprocedure(
        'public.post_backoffice_sales_credit_note(uuid,bigint,uuid)')))>0)
  UNION ALL
  SELECT 'retained_credit_permission_contract',
    CASE WHEN has_function_privilege('authenticated',
        'public.allocate_backoffice_sales_return_invoices(uuid,bigint,uuid,jsonb)','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.post_backoffice_sales_credit_note(uuid,bigint,uuid)','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.get_retained_retail_return_invoice_workspace(uuid)','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.get_backoffice_sales_credit_note_payment_context(uuid)','EXECUTE')
      AND NOT has_function_privilege('authenticated',
        'private.allocate_retained_retail_return_credit_core(uuid,bigint,uuid,jsonb)','EXECUTE')
      AND NOT has_function_privilege('authenticated',
        'private.post_retained_retail_credit_note_core(uuid,bigint,uuid)','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN has_function_privilege('authenticated',
        'public.allocate_backoffice_sales_return_invoices(uuid,bigint,uuid,jsonb)','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.post_backoffice_sales_credit_note(uuid,bigint,uuid)','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.get_retained_retail_return_invoice_workspace(uuid)','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.get_backoffice_sales_credit_note_payment_context(uuid)','EXECUTE')
      AND NOT has_function_privilege('authenticated',
        'private.allocate_retained_retail_return_credit_core(uuid,bigint,uuid,jsonb)','EXECUTE')
      AND NOT has_function_privilege('authenticated',
        'private.post_retained_retail_credit_note_core(uuid,bigint,uuid)','EXECUTE')
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('publicAuthenticated',true,'privateAuthenticated',false)
  UNION ALL
  SELECT 'retained_credit_native_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidNativeRows',count(*))
  FROM public.backoffice_sales_credit_notes note
  WHERE note.source_kind='BACKOFFICE'
    AND (note.source_invoice_id IS NULL OR note.source_retail_sales_id IS NOT NULL)
  UNION ALL
  SELECT 'retained_credit_runtime_inventory','INFO',0,
    jsonb_build_object('retainedNotes',count(*) FILTER(WHERE source_kind='RETAINED_RETAIL'),
      'retainedPosted',count(*) FILTER(WHERE source_kind='RETAINED_RETAIL' AND status='POSTED'),
      'nativeNotes',count(*) FILTER(WHERE source_kind='BACKOFFICE'))
  FROM public.backoffice_sales_credit_notes
) result ORDER BY status,check_name;
