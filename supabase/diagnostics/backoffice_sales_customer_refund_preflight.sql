-- SELECT-only preflight for Backoffice Sales Return Step 4/5.
WITH checks AS (
  SELECT 'refund_dependency_ledger' check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    (2-count(*))::bigint violation_rows,
    jsonb_build_object('expectedVersions',ARRAY['20260917130000','20260917131000'],
      'presentVersions',array_agg(version ORDER BY version)) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260917130000','20260917131000')
  UNION ALL
  SELECT 'refund_schema_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('existing',COALESCE(jsonb_agg(name ORDER BY name),'[]'::jsonb))
  FROM (SELECT name FROM (VALUES
      (CASE WHEN to_regclass('public.backoffice_sales_customer_refunds') IS NOT NULL
        THEN 'backoffice_sales_customer_refunds' END),
      (CASE WHEN to_regclass('public.backoffice_sales_customer_refund_operations') IS NOT NULL
        THEN 'backoffice_sales_customer_refund_operations' END),
      (CASE WHEN to_regclass('public.backoffice_sales_customer_refund_audit') IS NOT NULL
        THEN 'backoffice_sales_customer_refund_audit' END),
      (CASE WHEN to_regclass('private.backoffice_sales_customer_refund_no_seq') IS NOT NULL
        THEN 'backoffice_sales_customer_refund_no_seq' END),
      (CASE WHEN to_regprocedure('public.post_backoffice_sales_customer_refund(uuid,bigint,uuid,date,numeric,uuid,text,text,text)') IS NOT NULL
        THEN 'post_backoffice_sales_customer_refund' END),
      (CASE WHEN to_regprocedure('public.reverse_backoffice_sales_customer_refund(uuid,bigint,uuid,date,text)') IS NOT NULL
        THEN 'reverse_backoffice_sales_customer_refund' END),
      (CASE WHEN to_regprocedure('private.trg_provision_backoffice_customer_refund_category()') IS NOT NULL
        THEN 'trg_provision_backoffice_customer_refund_category' END)) candidate(name)
    WHERE name IS NOT NULL) collision
  UNION ALL
  SELECT 'refund_permission_event_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('existing',COALESCE(jsonb_agg(name ORDER BY name),'[]'::jsonb))
  FROM (SELECT 'finance.customer_refunds' name FROM public.access_permission_catalog
      WHERE permission_key='finance.customer_refunds'
    UNION ALL SELECT 'BACKOFFICE_CUSTOMER_REFUND' FROM public.system_events
      WHERE system_key='BACKOFFICE_CUSTOMER_REFUND'
    UNION ALL SELECT 'BO-CUSTOMER-REFUND category:'||category.company_id
      FROM public.transaction_categories category
      WHERE category.category_code='BO-CUSTOMER-REFUND'
        OR category.category_name='Refund Customer Backoffice') collision
  UNION ALL
  SELECT 'refund_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'refund_nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'refund_account_function_contract',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,
    (3-count(*))::bigint,jsonb_build_object('required',ARRAY[
      'CUSTOMER_REFUND_LIABILITY','CASH_DRAWER','BANK_RECEIPT'],
      'present',array_agg(function_key ORDER BY function_key))
  FROM public.account_functions WHERE is_active
    AND function_key IN('CUSTOMER_REFUND_LIABILITY','CASH_DRAWER','BANK_RECEIPT')
  UNION ALL
  SELECT 'refund_company_mapping_contract',
    CASE WHEN count(*) FILTER(WHERE invalid) =0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*) FILTER(WHERE invalid),jsonb_build_object('invalidCompanies',
      COALESCE(jsonb_agg(company_id ORDER BY company_id) FILTER(WHERE invalid),'[]'::jsonb))
  FROM (SELECT company.id company_id,
      NOT((SELECT count(*) FROM public.company_account_function_fallbacks fallback
          WHERE fallback.company_id=company.id
            AND fallback.account_function_key='CUSTOMER_REFUND_LIABILITY'
            AND fallback.status='ACTIVE'
            AND fallback.effective_from<=clock_timestamp()
            AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp()))=1
        AND (SELECT count(*) FROM public.company_account_function_fallbacks fallback
          WHERE fallback.company_id=company.id AND fallback.account_function_key='CASH_DRAWER'
            AND fallback.status='ACTIVE' AND fallback.effective_from<=clock_timestamp()
            AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp()))=1
        AND (SELECT count(*) FROM public.company_account_function_fallbacks fallback
          WHERE fallback.company_id=company.id AND fallback.account_function_key='BANK_RECEIPT'
            AND fallback.status='ACTIVE' AND fallback.effective_from<=clock_timestamp()
            AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp()))=1) invalid
    FROM public.companies company WHERE company.status='ACTIVE') scope
  UNION ALL
  SELECT 'refund_payment_method_contract',
    CASE WHEN count(*) FILTER(WHERE invalid)>0 THEN 'BLOCKER' ELSE 'PASS' END,
    count(*) FILTER(WHERE invalid),jsonb_build_object('invalidMethods',
      COALESCE(jsonb_agg(id ORDER BY id) FILTER(WHERE invalid),'[]'::jsonb))
  FROM (SELECT method.id,(method.settlement_route='DIRECT_BANK'
      AND (nullif(btrim(method.bank_account_function),'') IS NULL
        OR (SELECT count(*) FROM public.company_account_function_fallbacks fallback
          WHERE fallback.company_id=method.company_id
            AND fallback.account_function_key=method.bank_account_function
            AND fallback.status='ACTIVE' AND fallback.effective_from<=clock_timestamp()
            AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp()))<>1)) invalid
    FROM public.payment_methods method WHERE method.is_active
      AND method.settlement_route IN('CASH_DRAWER','DIRECT_BANK')) scope
  UNION ALL
  SELECT 'refund_existing_liability_inventory','INFO',0,
    jsonb_build_object('postedCreditNotes',count(*),
      'refundLiabilityTotal',COALESCE(sum(refund_liability_amount),0))
  FROM public.backoffice_sales_credit_notes
  WHERE status='POSTED' AND refund_liability_amount>0
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
