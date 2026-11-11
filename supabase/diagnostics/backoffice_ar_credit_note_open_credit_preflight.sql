-- SELECT-only Fase A production inventory for Backoffice AR Task 4.
-- No DDL, DML, context mutation, temp object, or deployment.
WITH required(version) AS (VALUES
  ('20260722150000'),('20260917130000'),('20260917131000'),
  ('20260918150000'),('20260919110000'),('20260928110000'),
  ('20261006140000'),('20261105100000'),('20261105110000')
), dependency AS (
  SELECT array_agg(required.version ORDER BY required.version)
      FILTER(WHERE migration.version IS NULL) AS missing,
    array_agg(required.version ORDER BY required.version)
      FILTER(WHERE migration.version IS NOT NULL) AS installed
  FROM required
  LEFT JOIN private.kgs_schema_migrations migration
    ON migration.version=required.version
), installation AS (
  SELECT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261105120000') AS ledger,
    to_regprocedure(
      'private.ar4_backoffice_invoice_allocated_credit(uuid,uuid,date)')
      IS NOT NULL AS allocated_credit_helper
), routines AS (
  SELECT to_regprocedure(
      'private.post_backoffice_sales_credit_note_before_retained(uuid,bigint,uuid)')
      AS native_post,
    to_regprocedure('public.post_backoffice_sales_credit_note(uuid,bigint,uuid)')
      AS public_post,
    to_regprocedure(
      'private.backoffice_invoice_receivable_before_receipts(uuid,uuid,date)')
      AS receivable,
    to_regprocedure(
      'private.reconcile_backoffice_invoice_receivable_schedule(uuid,uuid)')
      AS reconcile_schedule,
    to_regprocedure('public.get_finance_customer_receipts()') AS receipt_workspace,
    to_regprocedure(
      'public.get_backoffice_sales_invoice_payment_context_before_unified_revision(uuid)')
      AS payment_context_base,
    to_regprocedure('public.get_backoffice_sales_invoice_payment_context(uuid)')
      AS payment_context,
    to_regprocedure('public.get_finance_ar_aging(date,uuid,uuid)') AS ar_aging,
    to_regprocedure('private.plan_backoffice_invoice_revision_journals(uuid)')
      AS revision_plan,
    to_regprocedure('private.trg_ar_open_item_validate_allocation()')
      AS allocation_guard
), definitions AS (
  SELECT md5(pg_get_functiondef(native_post)) AS native_post_md5,
    md5(pg_get_functiondef(public_post)) AS public_post_md5,
    md5(pg_get_functiondef(receivable)) AS receivable_md5,
    md5(pg_get_functiondef(reconcile_schedule)) AS reconcile_md5,
    md5(pg_get_functiondef(receipt_workspace)) AS receipt_workspace_md5,
    md5(pg_get_functiondef(payment_context_base)) AS payment_context_base_md5,
    md5(pg_get_functiondef(payment_context)) AS payment_context_md5,
    md5(pg_get_functiondef(ar_aging)) AS ar_aging_md5,
    md5(pg_get_functiondef(revision_plan)) AS revision_plan_md5,
    md5(pg_get_functiondef(allocation_guard)) AS allocation_guard_md5,
    pg_get_functiondef(native_post) ILIKE
      '%v_ar:=least(v_note.grand_total,v_outstanding)%'
      AND pg_get_functiondef(native_post) ILIKE '%CUSTOMER_REFUND_LIABILITY%'
      AND pg_get_functiondef(native_post) ILIKE
        '%reconcile_backoffice_invoice_receivable_schedule%'
      AS native_legacy_split,
    pg_get_functiondef(public_post) ILIKE '%post_retained_retail_credit_note_core%'
      AND pg_get_functiondef(public_post) ILIKE
        '%post_backoffice_sales_credit_note_before_retained%'
      AS public_partition,
    pg_get_functiondef(receivable) ILIKE
      '%sum(note.grand_total)%backoffice_sales_credit_notes%'
      AS receivable_raw_credit,
    pg_get_functiondef(reconcile_schedule) ILIKE
      '%sum(note.ar_reduction_amount)%backoffice_sales_credit_notes%'
      AS schedule_raw_credit,
    pg_get_functiondef(receipt_workspace) ILIKE
      '%sum(note.ar_reduction_amount)%source_kind=''BACKOFFICE''%'
      AS workspace_raw_credit,
    pg_get_functiondef(payment_context_base) ILIKE
      '%sum(note.grand_total)%backoffice_sales_credit_notes%'
      AS payment_context_raw_credit,
    pg_get_functiondef(ar_aging) ILIKE
      '%sum(note.ar_reduction_amount)%source_invoice_id=invoice.id%'
      AS aging_raw_credit,
    pg_get_functiondef(revision_plan) ILIKE
      '%sum(n.ar_reduction_amount)%backoffice_sales_credit_notes%'
      AS revision_raw_credit,
    pg_get_functiondef(allocation_guard) ILIKE '%POST_RECEIPT%'
      AND pg_get_functiondef(allocation_guard) ILIKE '%BACKFILL_CREDIT_NOTE%'
      AS task3_allocation_guard
  FROM routines
), process_scope AS (
  SELECT company.id AS company_id,company.company_code,company.company_name,
    company.status,setting.active_mode,
    public.private_company_feature_enabled(company.id,'tax_sales_enabled')
      AS tax_sales_enabled
  FROM public.companies company
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=company.id
  WHERE setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
), category_state AS (
  SELECT scope.company_id,scope.company_code,
    count(category.id) FILTER(WHERE category.is_active) AS active_categories
  FROM process_scope scope
  LEFT JOIN public.transaction_categories category
    ON category.company_id=scope.company_id
    AND category.system_key='CUSTOMER_CREDIT_NOTE'
  GROUP BY scope.company_id,scope.company_code
), credit_inventory AS (
  SELECT note.company_id,note.source_kind,note.status,count(*) AS rows,
    round(COALESCE(sum(note.grand_total),0),4) AS grand_total,
    round(COALESCE(sum(note.ar_reduction_amount),0),4) AS ar_reduction,
    round(COALESCE(sum(note.refund_liability_amount),0),4) AS refund_liability
  FROM public.backoffice_sales_credit_notes note
  JOIN process_scope scope ON scope.company_id=note.company_id
  GROUP BY note.company_id,note.source_kind,note.status
), native_posted AS (
  SELECT note.company_id,note.id,note.credit_note_no,note.source_invoice_id,
    note.customer_id,note.credit_note_date,note.grand_total,
    note.ar_reduction_amount,note.refund_liability_amount,
    item.id AS credit_item_id,item.original_amount,
    COALESCE((SELECT sum(allocation.allocated_amount)
      FROM public.ar_open_item_allocations allocation
      WHERE allocation.company_id=item.company_id
        AND allocation.credit_item_id=item.id),0)::numeric(24,4)
      AS allocated_amount,
    (SELECT count(*) FROM public.finance_journals journal
      JOIN public.finance_journal_lines line
        ON line.company_id=journal.company_id AND line.journal_id=journal.id
      WHERE journal.company_id=note.company_id
        AND journal.financial_event_id=note.financial_event_id
        AND journal.status='POSTED' AND line.customer_id=note.customer_id
        AND line.debit=0 AND line.credit=note.ar_reduction_amount) AS ar_line_rows
  FROM public.backoffice_sales_credit_notes note
  JOIN process_scope scope ON scope.company_id=note.company_id
  LEFT JOIN public.ar_open_item_registry item
    ON item.company_id=note.company_id AND item.scope_kind='BACKOFFICE'
    AND item.item_kind='CREDIT_NOTE' AND item.source_id=note.id
  WHERE note.source_kind='BACKOFFICE' AND note.status='POSTED'
), draft_inventory AS (
  SELECT note.company_id,count(*) AS rows,
    round(COALESCE(sum(note.grand_total),0),4) AS grand_total
  FROM public.backoffice_sales_credit_notes note
  JOIN process_scope scope ON scope.company_id=note.company_id
  WHERE note.source_kind='BACKOFFICE' AND note.status='DRAFT'
  GROUP BY note.company_id
), native_liability AS (
  SELECT note.company_id,note.id,note.credit_note_no,
    note.refund_liability_amount,
    round(note.refund_liability_amount-COALESCE(refund.net_amount,0),4)
      AS remaining_liability
  FROM public.backoffice_sales_credit_notes note
  JOIN process_scope scope ON scope.company_id=note.company_id
  LEFT JOIN LATERAL(SELECT sum(CASE document.document_kind
      WHEN 'REFUND' THEN document.amount WHEN 'REVERSAL' THEN -document.amount
      ELSE 0 END) AS net_amount
    FROM public.backoffice_sales_customer_refunds document
    WHERE document.company_id=note.company_id
      AND document.credit_note_id=note.id AND document.status='POSTED') refund ON true
  WHERE note.source_kind='BACKOFFICE' AND note.status='POSTED'
    AND note.refund_liability_amount>0
), queue_state AS (
  SELECT (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))
      AS active_finance_queue,
    (SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION'))
      AS nonterminal_offline
)
SELECT 'backoffice_ar_credit_note_open_credit_preflight_dependency_ledger'
    AS check_name,
  CASE WHEN missing IS NULL THEN 'PASS' ELSE 'BLOCKER' END AS status,
  COALESCE(cardinality(missing),0)::bigint AS violation_rows,
  jsonb_build_object('missing',COALESCE(to_jsonb(missing),'[]'::jsonb),
    'installed',COALESCE(to_jsonb(installed),'[]'::jsonb)) AS details
FROM dependency
UNION ALL
SELECT 'backoffice_ar_credit_note_open_credit_preflight_installation_state',
  CASE WHEN NOT ledger AND NOT allocated_credit_helper THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN NOT ledger AND NOT allocated_credit_helper THEN 0 ELSE 1 END,
  jsonb_build_object('classification',CASE
    WHEN NOT ledger AND NOT allocated_credit_helper THEN 'NOT_INSTALLED'
    WHEN ledger AND allocated_credit_helper THEN 'INSTALLED_CONSISTENT'
    ELSE 'PARTIAL/INCONSISTENT' END,'ledger',ledger,
    'allocatedCreditHelper',allocated_credit_helper)
FROM installation
UNION ALL
SELECT 'backoffice_ar_credit_note_open_credit_preflight_runtime_anchors',
  CASE WHEN native_post IS NOT NULL AND public_post IS NOT NULL
      AND receivable IS NOT NULL AND reconcile_schedule IS NOT NULL
      AND receipt_workspace IS NOT NULL AND payment_context_base IS NOT NULL
      AND payment_context IS NOT NULL AND ar_aging IS NOT NULL
      AND revision_plan IS NOT NULL AND allocation_guard IS NOT NULL
      AND native_legacy_split AND public_partition AND receivable_raw_credit
      AND schedule_raw_credit AND workspace_raw_credit
      AND payment_context_raw_credit AND aging_raw_credit
      AND revision_raw_credit AND task3_allocation_guard
    THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN native_post IS NOT NULL AND public_post IS NOT NULL
      AND receivable IS NOT NULL AND reconcile_schedule IS NOT NULL
      AND receipt_workspace IS NOT NULL AND payment_context_base IS NOT NULL
      AND payment_context IS NOT NULL AND ar_aging IS NOT NULL
      AND revision_plan IS NOT NULL AND allocation_guard IS NOT NULL
      AND native_legacy_split AND public_partition AND receivable_raw_credit
      AND schedule_raw_credit AND workspace_raw_credit
      AND payment_context_raw_credit AND aging_raw_credit
      AND revision_raw_credit AND task3_allocation_guard
    THEN 0 ELSE 1 END,
  jsonb_build_object('nativePostMd5',native_post_md5,
    'publicPostMd5',public_post_md5,'receivableMd5',receivable_md5,
    'reconcileMd5',reconcile_md5,'receiptWorkspaceMd5',receipt_workspace_md5,
    'paymentContextBaseMd5',payment_context_base_md5,
    'paymentContextMd5',payment_context_md5,'arAgingMd5',ar_aging_md5,
    'revisionPlanMd5',revision_plan_md5,
    'allocationGuardMd5',allocation_guard_md5,
    'nativeLegacySplit',native_legacy_split,'publicPartition',public_partition,
    'receivableRawCredit',receivable_raw_credit,
    'scheduleRawCredit',schedule_raw_credit,
    'workspaceRawCredit',workspace_raw_credit,
    'paymentContextRawCredit',payment_context_raw_credit,
    'agingRawCredit',aging_raw_credit,'revisionRawCredit',revision_raw_credit,
    'task3AllocationGuard',task3_allocation_guard)
FROM routines CROSS JOIN definitions
UNION ALL
SELECT 'backoffice_ar_credit_note_open_credit_preflight_process_scope',
  CASE WHEN count(*)>0 AND count(*) FILTER(WHERE status<>'ACTIVE')=0
    THEN 'PASS' ELSE 'BLOCKER' END,
  count(*) FILTER(WHERE status<>'ACTIVE'),
  jsonb_build_object('companies',COALESCE(jsonb_agg(jsonb_build_object(
    'id',company_id,'code',company_code,'name',company_name,'status',status,
    'activeMode',active_mode,'taxSalesEnabled',tax_sales_enabled)
    ORDER BY company_code),'[]'::jsonb))
FROM process_scope
UNION ALL
SELECT 'backoffice_ar_credit_note_open_credit_preflight_tax_boundary',
  CASE WHEN count(*) FILTER(WHERE tax_sales_enabled)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  count(*) FILTER(WHERE tax_sales_enabled),
  jsonb_build_object('taxEnabledCompanies',COALESCE(jsonb_agg(company_code
    ORDER BY company_code) FILTER(WHERE tax_sales_enabled),'[]'::jsonb),
    'rule','Tax-enabled Backoffice Companies remain held pending approved Finance/Tax treatment')
FROM process_scope
UNION ALL
SELECT 'backoffice_ar_credit_note_open_credit_preflight_category_contract',
  CASE WHEN count(*) FILTER(WHERE active_categories<>1)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  count(*) FILTER(WHERE active_categories<>1),
  jsonb_build_object('companies',COALESCE(jsonb_agg(jsonb_build_object(
    'code',company_code,'activeCustomerCreditNoteCategories',active_categories)
    ORDER BY company_code),'[]'::jsonb))
FROM category_state
UNION ALL
SELECT 'backoffice_ar_credit_note_open_credit_preflight_historical_contract',
  CASE WHEN count(*) FILTER(WHERE credit_item_id IS NULL
        OR original_amount<>ar_reduction_amount
        OR allocated_amount<>ar_reduction_amount OR ar_line_rows<>1)=0
    THEN 'PASS' ELSE 'BLOCKER' END,
  count(*) FILTER(WHERE credit_item_id IS NULL
    OR original_amount<>ar_reduction_amount
    OR allocated_amount<>ar_reduction_amount OR ar_line_rows<>1),
  jsonb_build_object('postedNativeRows',count(*),
    'invalidRows',count(*) FILTER(WHERE credit_item_id IS NULL
      OR original_amount<>ar_reduction_amount
      OR allocated_amount<>ar_reduction_amount OR ar_line_rows<>1),
    'meaning','Every historical native Credit Note remains fully allocated as backfilled by Task 2')
FROM native_posted
UNION ALL
SELECT 'backoffice_ar_credit_note_open_credit_preflight_draft_inventory','INFO',0,
  jsonb_build_object('companies',COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'code',scope.company_code,'rows',COALESCE(draft.rows,0),
    'grandTotal',COALESCE(draft.grand_total,0)) ORDER BY scope.company_code)
    FROM process_scope scope LEFT JOIN draft_inventory draft
      ON draft.company_id=scope.company_id),'[]'::jsonb),
    'meaning','Existing Drafts adopt Task 4 semantics only after migration; installation mutates no Draft')
UNION ALL
SELECT 'backoffice_ar_credit_note_open_credit_preflight_credit_inventory','INFO',0,
  jsonb_build_object('rows',COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'company',company.company_code,'sourceKind',inventory.source_kind,
    'status',inventory.status,'rows',inventory.rows,
    'grandTotal',inventory.grand_total,'arReduction',inventory.ar_reduction,
    'refundLiability',inventory.refund_liability)
    ORDER BY company.company_code,inventory.source_kind,inventory.status)
    FROM credit_inventory inventory JOIN public.companies company
      ON company.id=inventory.company_id),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_credit_note_open_credit_preflight_native_liability','INFO',0,
  jsonb_build_object('rows',COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'company',company.company_code,'creditNoteId',liability.id,
    'creditNoteNo',liability.credit_note_no,
    'liability',liability.refund_liability_amount,
    'remaining',liability.remaining_liability)
    ORDER BY company.company_code,liability.credit_note_no)
    FROM native_liability liability JOIN public.companies company
      ON company.id=liability.company_id),'[]'::jsonb),
    'boundary','Historical liability/refund remains legacy and is not rewritten by Task 4')
UNION ALL
SELECT 'backoffice_ar_credit_note_open_credit_preflight_runtime_boundary',
  CASE WHEN active_finance_queue=0 AND nonterminal_offline=0
    THEN 'PASS' ELSE 'BLOCKER' END,
  active_finance_queue+nonterminal_offline,
  jsonb_build_object('activeFinanceQueue',active_finance_queue,
    'nonterminalOffline',nonterminal_offline)
FROM queue_state
UNION ALL
SELECT 'backoffice_ar_credit_note_open_credit_preflight_business_boundary','INFO',0,
  jsonb_build_object('mutation','NONE','planned',jsonb_build_array(
      'new native Backoffice Credit Note credits AR in full',
      'new native Credit Note becomes unallocated Customer-scoped open credit',
      'Invoice outstanding consumers use explicit Credit Note allocation'),
    'preserved',jsonb_build_array('RETAINED_RETAIL and POS Retail',
      'physical Return and Stock/FIFO/HPP','Customer Receipt Journal ownership',
      'Customer Statement net AR','Customer Balance','historical Posted Journal',
      'legacy Refund Liability and Refund','price correction'),
    'next','Only when every mandatory row PASS: show Phase B SOP Gate before any runtime edit');
