-- Read-only preflight for Backoffice Regular/DP Invoice Finance posting.
-- Target: isolated Development Supabase only.
-- SAFETY: SELECT-only. No Invoice, Event, Journal, Stock, POS, or Finance mutation.
WITH required_function(function_key) AS (
  VALUES ('CUSTOMER_RECEIVABLE'::text),('SALES_REVENUE'::text),
    ('OUTPUT_TAX'::text),('CUSTOMER_ADVANCE_LIABILITY'::text)
), active_company AS (
  SELECT company.id company_id,company.company_code
  FROM public.companies company WHERE company.status='ACTIVE'
), company_function AS (
  SELECT company.company_id,company.company_code,required.function_key
  FROM active_company company CROSS JOIN required_function required
), account_candidate AS (
  SELECT requirement.*,
    (SELECT count(DISTINCT rule.account_id)
     FROM public.transaction_account_rules rule
     JOIN public.transaction_categories category ON category.company_id=rule.company_id
      AND category.id=rule.transaction_category_id AND category.is_active
     JOIN public.chart_of_accounts account ON account.company_id=rule.company_id
      AND account.id=rule.account_id
     JOIN public.account_functions function_state
      ON function_state.function_key=requirement.function_key AND function_state.is_active
     WHERE rule.company_id=requirement.company_id AND rule.system_key='SALE_POSTED'
       AND category.system_key='SALE_POSTED'
       AND rule.account_function_key=requirement.function_key AND rule.status='ACTIVE'
       AND rule.effective_from<=clock_timestamp()
       AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())
       AND account.is_active AND account.is_postable
       AND account.account_type=ANY(function_state.compatible_account_types)) sale_rule_count,
    (SELECT count(DISTINCT rule.account_id)
     FROM public.transaction_account_rules rule
     JOIN public.transaction_categories category ON category.company_id=rule.company_id
      AND category.id=rule.transaction_category_id AND category.is_active
     JOIN public.chart_of_accounts account ON account.company_id=rule.company_id
      AND account.id=rule.account_id
     JOIN public.account_functions function_state
      ON function_state.function_key=requirement.function_key AND function_state.is_active
     WHERE rule.company_id=requirement.company_id AND rule.system_key='SALE_DISPATCHED'
       AND category.system_key='SALE_DISPATCHED'
       AND rule.account_function_key=requirement.function_key AND rule.status='ACTIVE'
       AND rule.effective_from<=clock_timestamp()
       AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())
       AND account.is_active AND account.is_postable
       AND account.account_type=ANY(function_state.compatible_account_types)) dispatch_rule_count,
    (SELECT count(DISTINCT fallback.account_id)
     FROM public.company_account_function_fallbacks fallback
     JOIN public.chart_of_accounts account ON account.company_id=fallback.company_id
      AND account.id=fallback.account_id
     JOIN public.account_functions function_state
      ON function_state.function_key=requirement.function_key AND function_state.is_active
     WHERE fallback.company_id=requirement.company_id
       AND fallback.account_function_key=requirement.function_key
       AND fallback.status='ACTIVE' AND fallback.effective_from<=clock_timestamp()
       AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp())
       AND account.is_active AND account.is_postable
       AND account.account_type=ANY(function_state.compatible_account_types)) fallback_count,
    (SELECT count(DISTINCT account.id)
     FROM public.chart_of_accounts account
     JOIN public.account_functions function_state
      ON function_state.function_key=requirement.function_key AND function_state.is_active
     WHERE account.company_id=requirement.company_id
       AND account.system_function_key=requirement.function_key
       AND account.is_system_account AND account.is_active AND account.is_postable
       AND account.account_type=ANY(function_state.compatible_account_types)) system_count
  FROM company_function requirement
), account_resolution AS (
  SELECT candidate.*,CASE
    WHEN sale_rule_count=1 THEN 'SALE_POSTED_RULE'
    WHEN sale_rule_count>1 THEN 'AMBIGUOUS_SALE_POSTED_RULE'
    WHEN dispatch_rule_count=1 THEN 'SALE_DISPATCHED_RULE'
    WHEN dispatch_rule_count>1 THEN 'AMBIGUOUS_SALE_DISPATCHED_RULE'
    WHEN fallback_count=1 THEN 'COMPANY_FALLBACK'
    WHEN fallback_count>1 THEN 'AMBIGUOUS_COMPANY_FALLBACK'
    WHEN system_count=1 THEN 'SYSTEM_ACCOUNT'
    WHEN system_count>1 THEN 'AMBIGUOUS_SYSTEM_ACCOUNT'
    ELSE 'MISSING' END resolution_source
  FROM account_candidate candidate
), invoice_reconciliation AS (
  SELECT invoice.company_id,invoice.id,invoice.invoice_type,invoice.status,
    invoice.charge_total,invoice.discount_total,invoice.tax_total,
    invoice.down_payment_deduction_total,invoice.grand_total,
    COALESCE(sum(line.line_amount) FILTER(WHERE line.effect_type='CHARGE'),0) line_charge,
    COALESCE(sum(line.discount_amount) FILTER(WHERE line.effect_type='CHARGE'),0) line_discount,
    COALESCE(sum(line.tax_amount) FILTER(WHERE line.effect_type='CHARGE'),0) line_tax,
    COALESCE(sum(line.line_amount) FILTER(WHERE line.effect_type='DEDUCTION'),0) line_deduction
  FROM public.backoffice_sales_invoices invoice
  LEFT JOIN public.backoffice_sales_invoice_lines line
    ON line.company_id=invoice.company_id AND line.invoice_id=invoice.id
  GROUP BY invoice.company_id,invoice.id,invoice.invoice_type,invoice.status,
    invoice.charge_total,invoice.discount_total,invoice.tax_total,
    invoice.down_payment_deduction_total,invoice.grand_total
), schedule_reconciliation AS (
  SELECT invoice.company_id,invoice.id,invoice.status,invoice.grand_total,
    COALESCE(sum(schedule.amount_due),0) schedule_total,count(schedule.id) schedule_rows
  FROM public.backoffice_sales_invoices invoice
  LEFT JOIN public.backoffice_sales_invoice_receivable_schedules schedule
    ON schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id
  GROUP BY invoice.company_id,invoice.id,invoice.status,invoice.grand_total
), quantity_reconciliation AS (
  SELECT line.company_id,line.id invoice_line_id,line.invoice_id,line.quantity_base,
    allocation.allocated_base_qty,allocation.status allocation_status,
    invoice.status invoice_status
  FROM public.backoffice_sales_invoice_lines line
  JOIN public.backoffice_sales_invoices invoice
    ON invoice.company_id=line.company_id AND invoice.id=line.invoice_id
  LEFT JOIN public.backoffice_sales_invoice_quantity_allocations allocation
    ON allocation.company_id=line.company_id AND allocation.invoice_line_id=line.id
  WHERE line.line_type='PRODUCT'
), checks AS (
  SELECT 'invoice_draft_runtime_dependencies'::text check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(2-count(*))::bigint violation_rows,
    jsonb_build_object('expected',2,'ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version IN('20260909157000','20260909158000')
  UNION ALL
  SELECT 'canonical_finance_runtime_dependencies',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,abs(3-count(*))::bigint,
    jsonb_build_object('expected',3,'routineRows',count(*))
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE namespace.nspname='private' AND proc.proname IN(
    'post_financial_event_core','f4b_financial_event_supported','resolve_financial_event_account')
  UNION ALL
  SELECT 'required_invoice_account_functions',
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'BLOCKER' END,(4-count(*))::bigint,
    jsonb_build_object('expected',4,'functionRows',count(*),'functions',
      COALESCE(jsonb_agg(account_function.function_key ORDER BY account_function.function_key),'[]'::jsonb))
  FROM public.account_functions account_function
  WHERE account_function.function_key IN(SELECT function_key FROM required_function)
    AND account_function.is_active
  UNION ALL
  SELECT 'invoice_account_source_coverage',
    CASE WHEN count(*) FILTER(WHERE resolution_source='MISSING'
      OR resolution_source LIKE 'AMBIGUOUS%')=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*) FILTER(WHERE resolution_source='MISSING'
      OR resolution_source LIKE 'AMBIGUOUS%')::bigint,
    jsonb_build_object('requirements',count(*),'invalid',COALESCE(jsonb_agg(
      jsonb_build_object('companyCode',company_code,'functionKey',function_key,
        'resolution',resolution_source,'saleRuleCount',sale_rule_count,
        'dispatchRuleCount',dispatch_rule_count,'fallbackCount',fallback_count,
        'systemCount',system_count) ORDER BY company_code,function_key)
      FILTER(WHERE resolution_source='MISSING' OR resolution_source LIKE 'AMBIGUOUS%'),'[]'::jsonb))
  FROM account_resolution
  UNION ALL
  SELECT 'invoice_finance_identity_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('collisionRows',count(*))
  FROM (SELECT event.system_key::text identity FROM public.system_events event
      WHERE event.system_key IN('BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT')
    UNION ALL SELECT category.id::text FROM public.transaction_categories category
      WHERE upper(regexp_replace(btrim(category.category_code),'\s+',' ','g'))
        IN('BO-SALE-INVOICE','BO-SALE-DOWN-PAYMENT')
      OR lower(regexp_replace(btrim(category.category_name),'\s+',' ','g'))
        IN('backoffice invoice penjualan','backoffice uang muka penjualan')) collision
  UNION ALL
  SELECT 'invoice_posting_runtime_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('routineRows',count(*))
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE namespace.nspname IN('private','public') AND proc.proname IN(
    'post_backoffice_sales_invoice_core','post_backoffice_sales_invoice',
    'post_backoffice_sales_invoice_financial_event_core')
  UNION ALL
  SELECT 'active_finance_posting_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'invoice_runtime_pre_posting_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('unexpectedPostedOrReversedRows',count(*))
  FROM public.backoffice_sales_invoices WHERE status IN('POSTED','REVERSED') OR invoice_no IS NOT NULL
    OR financial_event_id IS NOT NULL OR posted_at IS NOT NULL OR posted_by IS NOT NULL
  UNION ALL
  SELECT 'invoice_line_amount_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM invoice_reconciliation
  WHERE round(charge_total,4)<>round(line_charge+line_discount,4)
    OR round(discount_total,4)<>round(line_discount,4)
    OR round(tax_total,4)<>round(line_tax,4)
    OR round(down_payment_deduction_total,4)<>round(line_deduction,4)
    OR round(grand_total,4)<>round(line_charge+line_tax-line_deduction,4)
  UNION ALL
  SELECT 'invoice_schedule_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM schedule_reconciliation WHERE status='DRAFT'
    AND (schedule_rows=0 OR round(schedule_total,4)<>round(grand_total,4))
  UNION ALL
  SELECT 'draft_regular_quantity_hold_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM quantity_reconciliation WHERE invoice_status='DRAFT' AND (allocated_base_qty IS NULL
    OR round(allocated_base_qty,6)<>round(quantity_base,6) OR allocation_status<>'HELD')
  UNION ALL
  SELECT 'dp_proportional_tax_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_invoice_lines line
  JOIN public.backoffice_sales_invoices invoice
    ON invoice.company_id=line.company_id AND invoice.id=line.invoice_id
  WHERE invoice.invoice_type='DOWN_PAYMENT' AND line.line_type='DOWN_PAYMENT'
    AND (line.source_snapshot->>'calculation' IS DISTINCT FROM 'DPP_PLUS_PROPORTIONAL_TAX'
      OR COALESCE((line.source_snapshot->>'orderDpp')::numeric,0)<=0
      OR round(line.line_amount,4)<>round((line.source_snapshot->>'basisAmount')::numeric,4)
      OR round(line.tax_amount,4)<>round((line.source_snapshot->>'taxAmount')::numeric,4)
      OR round(line.tax_amount,4)<>round((line.source_snapshot->>'orderTax')::numeric
        *(line.source_snapshot->>'basisAmount')::numeric
        /(line.source_snapshot->>'orderDpp')::numeric,4))
  UNION ALL
  SELECT 'dp_tax_group_posting_contract','REVIEW',0::bigint,jsonb_build_object(
    'currentSnapshot','aggregate orderDpp/orderTax only',
    'decisionRequired','Split proportional DP tax by SO tax group/account or use one Company OUTPUT_TAX account',
    'draftDpRows',(SELECT count(*) FROM public.backoffice_sales_invoices
      WHERE status='DRAFT' AND invoice_type='DOWN_PAYMENT'),
    'ordersWithMultipleTaxAccounts',(SELECT count(*) FROM (SELECT line.company_id,line.sales_order_id
      FROM public.backoffice_sales_order_lines line WHERE line.tax_amount>0
      GROUP BY line.company_id,line.sales_order_id
      HAVING count(DISTINCT line.tax_account_id)>1) grouped))
  UNION ALL
  SELECT 'invoice_accounting_period_policy','REVIEW',0::bigint,jsonb_build_object(
    'decisionRequired','Block posting when invoice-date period is closed, or post to next open period as prior-period adjustment',
    'openPeriods',(SELECT count(*) FROM public.accounting_periods WHERE status IN('OPEN','REOPENED')),
    'draftInvoiceDatesWithoutOpenPeriod',(SELECT count(*) FROM public.backoffice_sales_invoices invoice
      WHERE invoice.status='DRAFT' AND NOT EXISTS(SELECT 1 FROM public.accounting_periods period
        WHERE period.company_id=invoice.company_id AND period.status IN('OPEN','REOPENED')
          AND invoice.invoice_date BETWEEN period.start_date AND period.end_date)))
  UNION ALL
  SELECT 'invoice_finance_runtime_inventory','INFO',0::bigint,jsonb_build_object(
    'activeCompanies',(SELECT count(*) FROM active_company),
    'draftRegular',(SELECT count(*) FROM public.backoffice_sales_invoices
      WHERE status='DRAFT' AND invoice_type='REGULAR'),
    'draftDownPayment',(SELECT count(*) FROM public.backoffice_sales_invoices
      WHERE status='DRAFT' AND invoice_type='DOWN_PAYMENT'),
    'canceled',(SELECT count(*) FROM public.backoffice_sales_invoices WHERE status='CANCELED'),
    'posted',(SELECT count(*) FROM public.backoffice_sales_invoices WHERE status='POSTED'),
    'postedPosSaleEvents',(SELECT count(*) FROM public.financial_events
      WHERE system_event_key='SALE_POSTED' AND source_table='sales_headers' AND status='POSTED'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1
  WHEN 'REVIEW' THEN 2 ELSE 3 END,check_name;
