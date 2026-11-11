-- SELECT-only postflight for Backoffice AR Task 4.
WITH migration AS (
  SELECT count(*) AS rows,max(applied_at) AS applied_at
  FROM private.kgs_schema_migrations WHERE version='20261105120000'
), runtime AS (
  SELECT to_regprocedure(
      'private.ar4_backoffice_invoice_allocated_credit(uuid,uuid,date)') AS helper,
    to_regprocedure(
      'private.ar4_register_backoffice_credit_note_open_item(uuid,uuid,uuid)') AS register_helper,
    to_regprocedure(
      'private.post_backoffice_sales_credit_note_before_retained(uuid,bigint,uuid)') AS native_post,
    to_regprocedure('public.post_backoffice_sales_credit_note(uuid,bigint,uuid)')
      AS public_post,
    to_regprocedure(
      'private.backoffice_invoice_receivable_before_receipts(uuid,uuid,date)') AS receivable,
    to_regprocedure(
      'private.reconcile_backoffice_invoice_receivable_schedule(uuid,uuid)') AS reconcile,
    to_regprocedure('public.get_finance_customer_receipts()') AS workspace,
    to_regprocedure(
      'public.get_backoffice_sales_invoice_payment_context_before_unified_revision(uuid)')
      AS payment_base,
    to_regprocedure('public.get_finance_ar_aging(date,uuid,uuid)') AS aging,
    to_regprocedure('private.plan_backoffice_invoice_revision_journals(uuid)')
      AS revision
), definitions AS (
  SELECT md5(pg_get_functiondef(helper)) AS helper_md5,
    md5(pg_get_functiondef(register_helper)) AS register_md5,
    md5(pg_get_functiondef(native_post)) AS native_post_md5,
    md5(pg_get_functiondef(public_post)) AS public_post_md5,
    pg_get_functiondef(native_post) ILIKE
      '%v_ar:=v_note.grand_total;v_refund:=0%'
      AND pg_get_functiondef(native_post) ILIKE
        '%ar4_register_backoffice_credit_note_open_item%'
      AND pg_get_functiondef(native_post) NOT ILIKE
        '%v_ar:=least(v_note.grand_total,v_outstanding)%'
      AND pg_get_functiondef(native_post) ILIKE
        '%AR_OPEN_ITEM_CREDIT_NOTE_TAX_TREATMENT_PENDING%'
      AS native_open_credit,
    md5(pg_get_functiondef(public_post))='93723ceab34fd6318088f314e976dd72'
      AND pg_get_functiondef(public_post) ILIKE
        '%post_retained_retail_credit_note_core%'
      AS retail_partition_preserved,
    pg_get_functiondef(receivable) ILIKE '%ar4_backoffice_invoice_allocated_credit%'
      AND pg_get_functiondef(reconcile) ILIKE '%ar4_backoffice_invoice_allocated_credit%'
      AND pg_get_functiondef(workspace) ILIKE '%ar4_backoffice_invoice_allocated_credit%'
      AND pg_get_functiondef(payment_base) ILIKE '%ar4_backoffice_invoice_allocated_credit%'
      AND pg_get_functiondef(aging) ILIKE '%ar4_backoffice_invoice_allocated_credit%'
      AND pg_get_functiondef(revision) ILIKE '%ar4_backoffice_invoice_allocated_credit%'
      AS consumers_allocation_based
  FROM runtime
), historical AS (
  SELECT count(*) AS rows,
    count(*) FILTER(WHERE item.id IS NULL
      OR item.original_amount<>note.ar_reduction_amount
      OR allocated.amount<>note.ar_reduction_amount) AS invalid
  FROM public.backoffice_sales_credit_notes note
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=note.company_id
    AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  LEFT JOIN public.ar_open_item_registry item
    ON item.company_id=note.company_id AND item.scope_kind='BACKOFFICE'
    AND item.item_kind='CREDIT_NOTE' AND item.source_id=note.id
  LEFT JOIN LATERAL(SELECT COALESCE(sum(allocation.allocated_amount),0) amount
    FROM public.ar_open_item_allocations allocation
    WHERE allocation.company_id=item.company_id
      AND allocation.credit_item_id=item.id) allocated ON true
  WHERE note.source_kind='BACKOFFICE' AND note.status='POSTED'
    AND COALESCE(item.source_snapshot->>'runtime','')<>'TASK4'
), task4_items AS (
  SELECT count(*) AS rows,count(*) FILTER(WHERE allocated.amount<>0
      OR note.id IS NULL OR note.status<>'POSTED' OR note.source_kind<>'BACKOFFICE'
      OR note.ar_reduction_amount<>note.grand_total
      OR note.refund_liability_amount<>0
      OR item.original_amount<>note.grand_total
      OR item.customer_id<>note.customer_id) AS invalid_rows
  FROM public.ar_open_item_registry item
  LEFT JOIN public.backoffice_sales_credit_notes note
    ON note.company_id=item.company_id AND note.id=item.source_id
  LEFT JOIN LATERAL(SELECT COALESCE(sum(allocation.allocated_amount),0) amount
    FROM public.ar_open_item_allocations allocation
    WHERE allocation.company_id=item.company_id
      AND allocation.credit_item_id=item.id) allocated ON true
  WHERE item.item_kind='CREDIT_NOTE'
    AND item.source_snapshot->>'runtime'='TASK4'
), zero_effect AS (
  SELECT (SELECT count(*) FROM public.financial_events event
      WHERE event.source_table='backoffice_sales_credit_notes'
        AND event.created_at>=migration.applied_at) AS event_rows,
    (SELECT count(*) FROM public.finance_journals journal
      WHERE journal.source_type='backoffice_sales_credit_notes'
        AND journal.created_at>=migration.applied_at) AS journal_rows
  FROM migration
)
SELECT 'backoffice_ar_credit_note_open_credit_postflight_migration_ledger'
    AS check_name,
  CASE WHEN rows=1 THEN 'PASS' ELSE 'FAIL' END AS status,
  CASE WHEN rows=1 THEN 0 ELSE 1 END AS violation_rows,
  jsonb_build_object('ledgerRows',rows,'appliedAt',applied_at) AS details
FROM migration
UNION ALL
SELECT 'backoffice_ar_credit_note_open_credit_postflight_runtime_contract',
  CASE WHEN helper IS NOT NULL AND register_helper IS NOT NULL
      AND native_post IS NOT NULL AND public_post IS NOT NULL
      AND receivable IS NOT NULL AND reconcile IS NOT NULL
      AND workspace IS NOT NULL AND payment_base IS NOT NULL
      AND aging IS NOT NULL AND revision IS NOT NULL
      AND native_open_credit AND retail_partition_preserved
      AND consumers_allocation_based THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN helper IS NOT NULL AND register_helper IS NOT NULL
      AND native_post IS NOT NULL AND public_post IS NOT NULL
      AND receivable IS NOT NULL AND reconcile IS NOT NULL
      AND workspace IS NOT NULL AND payment_base IS NOT NULL
      AND aging IS NOT NULL AND revision IS NOT NULL
      AND native_open_credit AND retail_partition_preserved
      AND consumers_allocation_based THEN 0 ELSE 1 END,
  jsonb_build_object('helperMd5',helper_md5,'registerMd5',register_md5,
    'nativePostMd5',native_post_md5,'publicPostMd5',public_post_md5,
    'nativeOpenCredit',native_open_credit,
    'retailPartitionPreserved',retail_partition_preserved,
    'consumersAllocationBased',consumers_allocation_based)
FROM runtime CROSS JOIN definitions
UNION ALL
SELECT 'backoffice_ar_credit_note_open_credit_postflight_historical_contract',
  CASE WHEN invalid=0 THEN 'PASS' ELSE 'FAIL' END,invalid,
  jsonb_build_object('postedNativeRows',rows,'invalidRows',invalid,
    'meaning','Historical native Credit Notes retain Task 2 full allocation')
FROM historical
UNION ALL
SELECT 'backoffice_ar_credit_note_open_credit_postflight_new_item_contract',
  CASE WHEN invalid_rows=0 THEN 'PASS' ELSE 'FAIL' END,invalid_rows,
  jsonb_build_object('task4Items',rows,'invalidRows',invalid_rows,
    'meaning','Task 4 Credit Notes are full-AR, zero-refund, unallocated open credits')
FROM task4_items
UNION ALL
SELECT 'backoffice_ar_credit_note_open_credit_postflight_installation_zero_effect',
  CASE WHEN event_rows=0 AND journal_rows=0 THEN 'PASS' ELSE 'REVIEW' END,
  event_rows+journal_rows,
  jsonb_build_object('creditNoteEventsSinceInstall',event_rows,
    'creditNoteJournalsSinceInstall',journal_rows,
    'meaning','Run immediately after migration and before authenticated posting smoke')
FROM zero_effect
UNION ALL
SELECT 'backoffice_ar_credit_note_open_credit_postflight_privilege_contract',
  CASE WHEN NOT has_function_privilege('authenticated',
      'private.ar4_backoffice_invoice_allocated_credit(uuid,uuid,date)','EXECUTE')
      AND NOT has_function_privilege('authenticated',
        'private.ar4_register_backoffice_credit_note_open_item(uuid,uuid,uuid)','EXECUTE')
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN NOT has_function_privilege('authenticated',
      'private.ar4_backoffice_invoice_allocated_credit(uuid,uuid,date)','EXECUTE')
      AND NOT has_function_privilege('authenticated',
        'private.ar4_register_backoffice_credit_note_open_item(uuid,uuid,uuid)','EXECUTE')
    THEN 0 ELSE 1 END,
  jsonb_build_object('allocatedHelperAuthenticated',has_function_privilege(
      'authenticated','private.ar4_backoffice_invoice_allocated_credit(uuid,uuid,date)','EXECUTE'),
    'registerHelperAuthenticated',has_function_privilege(
      'authenticated','private.ar4_register_backoffice_credit_note_open_item(uuid,uuid,uuid)','EXECUTE'))
UNION ALL
SELECT 'backoffice_ar_credit_note_open_credit_postflight_business_boundary','INFO',0,
  jsonb_build_object('changed',jsonb_build_array(
      'future native Backoffice Credit Note credits AR in full',
      'future native Credit Note registers unallocated open credit',
      'Invoice consumers use explicit Credit Note allocation'),
    'preserved',jsonb_build_array('RETAINED_RETAIL and POS Retail',
      'Stock/FIFO/HPP','Customer Statement net AR','Customer Balance',
      'price correction','historical Credit Note allocation',
      'legacy Refund Liability and Refund','Posted Journals'),
    'next','Run rollback-only behavior before any client smoke');
