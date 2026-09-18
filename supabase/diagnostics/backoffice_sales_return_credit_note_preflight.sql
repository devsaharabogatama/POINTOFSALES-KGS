-- SELECT-only preflight for Backoffice Sales Return Step 3/5.
WITH checks AS (
  SELECT 'step3_dependency_ledger' check_name,
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'BLOCKER' END status,
    4-count(*) violation_rows,
    jsonb_build_object('expected',4,'present',count(*),'requiredVersions',
      ARRAY['20260917110000','20260917120000','20260917121000','20260917122000']) details
  FROM private.kgs_schema_migrations
  WHERE version=ANY(ARRAY['20260917110000','20260917120000','20260917121000','20260917122000'])
  UNION ALL
  SELECT 'step3_schema_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('existing',COALESCE(jsonb_agg(name ORDER BY name),'[]'::jsonb))
  FROM (SELECT unnest(ARRAY[
    CASE WHEN to_regclass('public.backoffice_sales_credit_notes') IS NOT NULL
      THEN 'backoffice_sales_credit_notes' END,
    CASE WHEN to_regclass('public.backoffice_sales_credit_note_lines') IS NOT NULL
      THEN 'backoffice_sales_credit_note_lines' END,
    CASE WHEN to_regclass('public.backoffice_sales_return_invoice_allocations') IS NOT NULL
      THEN 'backoffice_sales_return_invoice_allocations' END,
    CASE WHEN to_regclass('public.backoffice_sales_credit_note_operations') IS NOT NULL
      THEN 'backoffice_sales_credit_note_operations' END,
    CASE WHEN to_regclass('public.backoffice_sales_credit_note_audit') IS NOT NULL
      THEN 'backoffice_sales_credit_note_audit' END]) name) collision WHERE name IS NOT NULL
  UNION ALL
  SELECT 'step3_runtime_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('existing',COALESCE(jsonb_agg(name ORDER BY name),'[]'::jsonb))
  FROM (SELECT unnest(ARRAY[
    CASE WHEN to_regprocedure('public.allocate_backoffice_sales_return_invoices(uuid,bigint,uuid,jsonb)') IS NOT NULL
      THEN 'allocate_backoffice_sales_return_invoices' END,
    CASE WHEN to_regprocedure('public.update_backoffice_sales_credit_note_draft(uuid,bigint,uuid,date,numeric,text)') IS NOT NULL
      THEN 'update_backoffice_sales_credit_note_draft' END,
    CASE WHEN to_regprocedure('public.post_backoffice_sales_credit_note(uuid,bigint,uuid)') IS NOT NULL
      THEN 'post_backoffice_sales_credit_note' END]) name) collision WHERE name IS NOT NULL
  UNION ALL
  SELECT 'step3_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'step3_nonterminal_offline',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'step3_finance_master_contract',
    CASE WHEN count(DISTINCT function_key)=5
      AND EXISTS(SELECT 1 FROM public.system_events WHERE system_key='CUSTOMER_CREDIT_NOTE')
      THEN 'PASS' ELSE 'BLOCKER' END,
    5-count(DISTINCT function_key),jsonb_build_object(
      'requiredFunctions',ARRAY['CUSTOMER_RECEIVABLE','CUSTOMER_REFUND_LIABILITY',
        'SALES_RETURN_DISCOUNT','OUTPUT_TAX','DELIVERY_FEE_REVENUE'],
      'presentFunctions',COALESCE(jsonb_agg(function_key ORDER BY function_key),'[]'::jsonb))
  FROM public.account_functions
  WHERE is_active AND function_key=ANY(ARRAY['CUSTOMER_RECEIVABLE','CUSTOMER_REFUND_LIABILITY',
    'SALES_RETURN_DISCOUNT','OUTPUT_TAX','DELIVERY_FEE_REVENUE'])
  UNION ALL
  SELECT 'step3_canonical_account_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('invalidCompanies',count(*),'required',
      'Exactly one active postable system account per Credit Note function')
  FROM (SELECT company.id,key.function_key
    FROM public.companies company
    CROSS JOIN unnest(ARRAY['CUSTOMER_RECEIVABLE','CUSTOMER_REFUND_LIABILITY',
      'SALES_RETURN_DISCOUNT','DELIVERY_FEE_REVENUE']) key(function_key)
    LEFT JOIN public.chart_of_accounts account ON account.company_id=company.id
      AND account.system_function_key=key.function_key AND account.is_system_account
      AND account.is_active AND account.is_postable
    WHERE company.status='ACTIVE'
    GROUP BY company.id,key.function_key HAVING count(account.id)<>1) invalid
  UNION ALL
  SELECT 'step3_current_fallback_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('invalidCompanyFunctions',count(*),'rule',
      'Each required function has zero fallback to provision, or exactly one current fallback')
  FROM (SELECT company.id,key.function_key
    FROM public.companies company
    CROSS JOIN unnest(ARRAY['CUSTOMER_RECEIVABLE','CUSTOMER_REFUND_LIABILITY',
      'SALES_RETURN_DISCOUNT','DELIVERY_FEE_REVENUE']) key(function_key)
    LEFT JOIN public.company_account_function_fallbacks fallback
      ON fallback.company_id=company.id
      AND fallback.account_function_key=key.function_key AND fallback.status='ACTIVE'
    WHERE company.status='ACTIVE'
    GROUP BY company.id,key.function_key
    HAVING count(fallback.id)>0 AND count(fallback.id) FILTER(
      WHERE fallback.effective_from<=clock_timestamp()
        AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp()))<>1) invalid
  UNION ALL
  SELECT 'step3_credit_note_category_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('invalidCompanies',count(*),'required',
      'Exactly one or more active CUSTOMER_CREDIT_NOTE category per active Company')
  FROM (SELECT company.id FROM public.companies company
    LEFT JOIN public.transaction_categories category ON category.company_id=company.id
      AND category.system_key='CUSTOMER_CREDIT_NOTE' AND category.is_active
    WHERE company.status='ACTIVE' GROUP BY company.id HAVING count(category.id)=0) invalid
  UNION ALL
  SELECT 'step3_runtime_inventory','INFO',0,jsonb_build_object(
    'receivedReturnLines',(SELECT count(*) FROM public.backoffice_sales_return_receipt_lines),
    'postedInvoices',(SELECT count(*) FROM public.backoffice_sales_invoices WHERE status='POSTED'),
    'draftInvoices',(SELECT count(*) FROM public.backoffice_sales_invoices WHERE status='DRAFT'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
