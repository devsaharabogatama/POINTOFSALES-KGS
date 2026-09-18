-- SELECT-only preflight for 20260918140000. Run the entire file.
WITH target(company_id,company_name) AS (VALUES
  ('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,'Khadijah Muda Sejahtera'),
  ('809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid,'Smart Muda Solusi'),
  ('07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,'Latorti Sari Median')
), target_shape AS (
 SELECT target.*,
  (SELECT count(*) FROM public.companies company WHERE company.id=target.company_id
    AND company.status='ACTIVE') company_rows,
  (SELECT count(*) FROM public.chart_of_accounts account
    WHERE account.company_id=target.company_id AND account.account_code='1010100-1'
      AND account.account_name='BANK BCA' AND account.account_type='ASSET'
      AND account.is_active AND account.is_postable) bca_rows,
  (SELECT count(*) FROM public.transaction_categories category
    WHERE category.company_id=target.company_id AND category.system_key='SALE_PAYMENT'
      AND category.is_active) category_rows,
  (SELECT count(*) FROM public.transaction_account_rules rule
    JOIN public.transaction_categories category ON category.company_id=rule.company_id
      AND category.id=rule.transaction_category_id
    JOIN public.chart_of_accounts account ON account.company_id=rule.company_id
      AND account.id=rule.account_id
    WHERE rule.company_id=target.company_id AND category.system_key='SALE_PAYMENT'
      AND rule.account_function_key='BANK' AND rule.status='ACTIVE'
      AND rule.effective_to IS NULL AND account.account_code='1010100-1'
      AND account.account_name='BANK BCA') open_bca_rule_rows,
  (SELECT count(*) FROM public.transaction_account_rules rule
    JOIN public.transaction_categories category ON category.company_id=rule.company_id
      AND category.id=rule.transaction_category_id
    WHERE rule.company_id=target.company_id AND category.system_key='SALE_PAYMENT'
      AND rule.account_function_key='BANK' AND rule.status='ACTIVE'
      AND rule.id<>(SELECT open_rule.id FROM public.transaction_account_rules open_rule
        JOIN public.transaction_categories open_category
          ON open_category.company_id=open_rule.company_id
         AND open_category.id=open_rule.transaction_category_id
        JOIN public.chart_of_accounts open_account
          ON open_account.company_id=open_rule.company_id
         AND open_account.id=open_rule.account_id
        WHERE open_rule.company_id=target.company_id
          AND open_category.system_key='SALE_PAYMENT'
          AND open_rule.account_function_key='BANK' AND open_rule.status='ACTIVE'
          AND open_rule.effective_to IS NULL AND open_account.account_code='1010100-1'
          AND open_account.account_name='BANK BCA' LIMIT 1)
      AND tstzrange(rule.effective_from,rule.effective_to,'[)') &&
        tstzrange('-infinity'::timestamptz,(SELECT open_rule.effective_from
          FROM public.transaction_account_rules open_rule
          JOIN public.transaction_categories open_category
            ON open_category.company_id=open_rule.company_id
           AND open_category.id=open_rule.transaction_category_id
          JOIN public.chart_of_accounts open_account
            ON open_account.company_id=open_rule.company_id
           AND open_account.id=open_rule.account_id
          WHERE open_rule.company_id=target.company_id
            AND open_category.system_key='SALE_PAYMENT'
            AND open_rule.account_function_key='BANK' AND open_rule.status='ACTIVE'
            AND open_rule.effective_to IS NULL AND open_account.account_code='1010100-1'
            AND open_account.account_name='BANK BCA' LIMIT 1),'[)')) historical_overlap_rows
 FROM target
), bca AS (
 SELECT target.company_id,account.id account_id
 FROM target JOIN public.chart_of_accounts account ON account.company_id=target.company_id
  AND account.account_code='1010100-1' AND account.account_name='BANK BCA'
  AND account.account_type='ASSET' AND account.is_active AND account.is_postable
), candidates AS (
 SELECT receipt.company_id,receipt.id receipt_id,receipt.receipt_no,receipt.receipt_date,
  receipt.total_amount,receipt.receipt_account_id_snapshot old_account_id,bca.account_id bca_account_id
 FROM public.customer_receipt_documents receipt JOIN bca ON bca.company_id=receipt.company_id
 WHERE receipt.status='POSTED' AND receipt.settlement_route_snapshot='DIRECT_BANK'
  AND receipt.receipt_account_id_snapshot IS DISTINCT FROM bca.account_id
), invalid_source AS (
 SELECT candidate.* FROM candidates candidate
 WHERE (SELECT count(*) FROM public.finance_journals journal
    WHERE journal.company_id=candidate.company_id
      AND journal.source_type='customer_receipt_documents'
      AND journal.source_id=candidate.receipt_id AND journal.system_event_key='SALE_PAYMENT'
      AND journal.status='POSTED')<>1
   OR (SELECT count(*) FROM public.finance_journals journal
      JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
       AND line.journal_id=journal.id
      WHERE journal.company_id=candidate.company_id
       AND journal.source_type='customer_receipt_documents'
       AND journal.source_id=candidate.receipt_id AND journal.system_event_key='SALE_PAYMENT'
       AND journal.status='POSTED' AND line.account_id=candidate.old_account_id
       AND line.debit=candidate.total_amount AND line.credit=0)<>1
   OR (SELECT count(*) FROM public.chart_of_accounts account
      WHERE account.company_id=candidate.company_id AND account.id=candidate.old_account_id
       AND account.is_active AND account.is_postable)<>1
   OR (SELECT count(*) FROM public.accounting_periods period
      WHERE period.company_id=candidate.company_id
       AND candidate.receipt_date BETWEEN period.start_date AND period.end_date
       AND period.status IN('OPEN','REOPENED'))<>1
), checks AS (
 SELECT 'receipt_bca_dependency_ledger' check_name,
  CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
  (2-count(*))::bigint violation_rows,
  jsonb_build_object('present',count(*),'expected',2) details
 FROM private.kgs_schema_migrations WHERE version IN('20260827110000','20260911163000')
 UNION ALL
 SELECT 'receipt_bca_target_master_contract',
  CASE WHEN count(*) FILTER(WHERE company_rows<>1 OR bca_rows<>1 OR category_rows<>1)=0
    THEN 'PASS' ELSE 'BLOCKER' END,
  count(*) FILTER(WHERE company_rows<>1 OR bca_rows<>1 OR category_rows<>1)::bigint,
  jsonb_build_object('companies',jsonb_agg(jsonb_build_object('companyId',company_id,
    'companyName',company_name,'companyRows',company_rows,'bcaRows',bca_rows,
    'categoryRows',category_rows) ORDER BY company_name))
 FROM target_shape
 UNION ALL
 SELECT 'receipt_bca_open_rule_contract',
  CASE WHEN count(*) FILTER(WHERE open_bca_rule_rows<>1 OR historical_overlap_rows<>0)=0
    THEN 'PASS' ELSE 'BLOCKER' END,
  count(*) FILTER(WHERE open_bca_rule_rows<>1 OR historical_overlap_rows<>0)::bigint,
  jsonb_build_object('companies',jsonb_agg(jsonb_build_object('companyId',company_id,
    'companyName',company_name,'openBcaRuleRows',open_bca_rule_rows,
    'historicalOverlapRows',historical_overlap_rows) ORDER BY company_name))
 FROM target_shape
 UNION ALL
 SELECT 'receipt_bca_source_journal_contract',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
  jsonb_build_object('invalidReceipts',count(*)) FROM invalid_source
 UNION ALL
 SELECT 'receipt_bca_active_finance_queue',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
  jsonb_build_object('runRows',count(*)) FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
 UNION ALL
 SELECT 'receipt_bca_existing_reclassification',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
  jsonb_build_object('journalRows',count(*)) FROM public.finance_journals journal
  JOIN target ON target.company_id=journal.company_id
  WHERE journal.source_type='CUSTOMER_RECEIPT_BANK_RECLASSIFICATION'
 UNION ALL
 SELECT 'receipt_bca_runtime_inventory','INFO',0,
  jsonb_build_object('candidateReceipts',count(*),'totalAmount',COALESCE(sum(total_amount),0),
    'companies',count(DISTINCT company_id)) FROM candidates
)
SELECT * FROM checks ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1
 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
