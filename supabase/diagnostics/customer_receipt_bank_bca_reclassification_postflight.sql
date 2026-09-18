-- SELECT-only postflight for 20260918140000. Run the entire file.
WITH target(company_id,company_name) AS (VALUES
  ('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,'Khadijah Muda Sejahtera'),
  ('809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid,'Smart Muda Solusi'),
  ('07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,'Latorti Sari Median')
), bca AS (
 SELECT target.company_id,target.company_name,account.id account_id
 FROM target JOIN public.chart_of_accounts account ON account.company_id=target.company_id
  AND account.account_code='1010100-1' AND account.account_name='BANK BCA'
  AND account.account_type='ASSET' AND account.is_active AND account.is_postable
), mapping_shape AS (
 SELECT bca.*,
  (SELECT count(*) FROM public.transaction_account_rules rule
   JOIN public.transaction_categories category ON category.company_id=rule.company_id
    AND category.id=rule.transaction_category_id
   WHERE rule.company_id=bca.company_id AND category.system_key='SALE_PAYMENT'
    AND rule.account_function_key='BANK' AND rule.account_id=bca.account_id
    AND rule.status='ACTIVE' AND rule.effective_from<='2000-01-01 12:00:00+00'::timestamptz
    AND (rule.effective_to IS NULL
      OR rule.effective_to>'2000-01-01 12:00:00+00'::timestamptz)) historical_rows,
  (SELECT count(*) FROM public.transaction_account_rules rule
   JOIN public.transaction_categories category ON category.company_id=rule.company_id
    AND category.id=rule.transaction_category_id
   WHERE rule.company_id=bca.company_id AND category.system_key='SALE_PAYMENT'
    AND rule.account_function_key='BANK' AND rule.account_id=bca.account_id
    AND rule.status='ACTIVE' AND rule.effective_from<=clock_timestamp()
    AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())) current_rows
 FROM bca
), bank_receipts AS (
 SELECT receipt.*,bca.account_id bca_account_id
 FROM public.customer_receipt_documents receipt JOIN bca ON bca.company_id=receipt.company_id
 WHERE receipt.status='POSTED' AND receipt.settlement_route_snapshot='DIRECT_BANK'
), invalid_mapping AS (
 SELECT receipt.company_id,receipt.id FROM bank_receipts receipt
 WHERE (SELECT count(*) FROM public.transaction_account_rules rule
   JOIN public.transaction_categories category ON category.company_id=rule.company_id
    AND category.id=rule.transaction_category_id
   WHERE rule.company_id=receipt.company_id AND category.system_key='SALE_PAYMENT'
    AND rule.account_function_key='BANK' AND rule.account_id=receipt.bca_account_id
    AND rule.status='ACTIVE'
    AND rule.effective_from<=receipt.receipt_date::timestamptz
    AND (rule.effective_to IS NULL OR rule.effective_to>receipt.receipt_date::timestamptz))<>1
), invalid_reclass AS (
 SELECT receipt.company_id,receipt.id FROM bank_receipts receipt
 WHERE receipt.receipt_account_id_snapshot IS DISTINCT FROM receipt.bca_account_id
  AND (SELECT count(*) FROM public.finance_journals journal
   WHERE journal.company_id=receipt.company_id
    AND journal.source_type='CUSTOMER_RECEIPT_BANK_RECLASSIFICATION'
    AND journal.source_id=receipt.id AND journal.status='POSTED'
    AND journal.accounting_date=receipt.receipt_date
    AND journal.total_debit=receipt.total_amount AND journal.total_credit=receipt.total_amount
    AND EXISTS(SELECT 1 FROM public.finance_journal_lines debit_line
      WHERE debit_line.company_id=journal.company_id AND debit_line.journal_id=journal.id
       AND debit_line.line_no=1 AND debit_line.account_id=receipt.bca_account_id
       AND debit_line.debit=receipt.total_amount AND debit_line.credit=0)
    AND EXISTS(SELECT 1 FROM public.finance_journal_lines credit_line
      WHERE credit_line.company_id=journal.company_id AND credit_line.journal_id=journal.id
       AND credit_line.line_no=2 AND credit_line.account_id=receipt.receipt_account_id_snapshot
       AND credit_line.credit=receipt.total_amount AND credit_line.debit=0))<>1
), checks AS (
 SELECT 'receipt_bca_reclassification_ledger' check_name,
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
  abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
 FROM private.kgs_schema_migrations WHERE version='20260918140000'
 UNION ALL
 SELECT 'receipt_bca_target_account_contract',
  CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,abs(3-count(*))::bigint,
 jsonb_build_object('present',count(*),'expected',3) FROM bca
 UNION ALL
 SELECT 'receipt_bca_exact_mapping_contract',
  CASE WHEN count(*) FILTER(WHERE historical_rows<>1 OR current_rows<>1)=0
    AND count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
  (count(*) FILTER(WHERE historical_rows<>1 OR current_rows<>1)+abs(3-count(*)))::bigint,
  jsonb_build_object('companies',jsonb_agg(jsonb_build_object('companyId',company_id,
   'companyName',company_name,'historicalRows',historical_rows,
   'currentRows',current_rows) ORDER BY company_name)) FROM mapping_shape
 UNION ALL
 SELECT 'receipt_bca_historical_mapping_coverage',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
  jsonb_build_object('invalidReceipts',count(*)) FROM invalid_mapping
 UNION ALL
 SELECT 'receipt_bca_posted_reclassification',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
  jsonb_build_object('invalidReceipts',count(*)) FROM invalid_reclass
 UNION ALL
 SELECT 'receipt_bca_cash_boundary',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
  jsonb_build_object('invalidCashCorrections',count(*))
 FROM public.finance_journals journal
 JOIN public.customer_receipt_documents receipt ON receipt.company_id=journal.company_id
  AND receipt.id=journal.source_id
 WHERE journal.source_type='CUSTOMER_RECEIPT_BANK_RECLASSIFICATION'
  AND receipt.settlement_route_snapshot<>'DIRECT_BANK'
 UNION ALL
 SELECT 'receipt_bca_reclassification_balance',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
  jsonb_build_object('invalidJournals',count(*)) FROM public.finance_journals journal
 JOIN target ON target.company_id=journal.company_id
 WHERE journal.source_type='CUSTOMER_RECEIPT_BANK_RECLASSIFICATION'
  AND (journal.status<>'POSTED' OR journal.total_debit<=0
   OR journal.total_debit<>journal.total_credit)
 UNION ALL
 SELECT 'receipt_bca_runtime_inventory','INFO',0,jsonb_build_object(
  'postedBankReceipts',count(*),
  'nativeBcaReceipts',count(*) FILTER(WHERE receipt_account_id_snapshot=bca_account_id),
  'reclassifiedReceipts',count(*) FILTER(WHERE receipt_account_id_snapshot<>bca_account_id),
  'totalAmount',COALESCE(sum(total_amount),0)) FROM bank_receipts
)
SELECT * FROM checks ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1
 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
