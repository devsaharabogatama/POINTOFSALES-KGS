-- SELECT-only trace of Finance mapping versions relevant to Customer Receipt.
-- Run the complete file. No Finance master or transaction row is changed.
WITH mapping_versions AS (
  SELECT 'TRANSACTION_RULE' mapping_kind,rule.company_id,company.company_name,
    rule.id mapping_id,category.category_name,category.system_key,
    rule.account_function_key,rule.account_id,account.account_code,
    account.account_name,account.account_type,account.is_active account_active,
    account.is_postable account_postable,rule.status,rule.rule_version version,
    rule.effective_from,rule.effective_to,rule.created_at,rule.updated_at,
    (rule.status='ACTIVE' AND rule.effective_from<=clock_timestamp()
      AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())) effective_now
  FROM public.transaction_account_rules rule
  JOIN public.companies company ON company.id=rule.company_id
  JOIN public.transaction_categories category
    ON category.company_id=rule.company_id AND category.id=rule.transaction_category_id
  JOIN public.chart_of_accounts account
    ON account.company_id=rule.company_id AND account.id=rule.account_id
  WHERE rule.system_key='SALE_PAYMENT'
     OR rule.account_function_key IN('BANK','CASH_DRAWER','CUSTOMER_RECEIVABLE')
  UNION ALL
  SELECT 'COMPANY_FALLBACK',fallback.company_id,company.company_name,
    fallback.id,NULL,NULL,fallback.account_function_key,fallback.account_id,
    account.account_code,account.account_name,account.account_type,
    account.is_active,account.is_postable,fallback.status,
    fallback.fallback_version,fallback.effective_from,fallback.effective_to,
    fallback.created_at,fallback.updated_at,
    (fallback.status='ACTIVE' AND fallback.effective_from<=clock_timestamp()
      AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp()))
  FROM public.company_account_function_fallbacks fallback
  JOIN public.companies company ON company.id=fallback.company_id
  JOIN public.chart_of_accounts account
    ON account.company_id=fallback.company_id AND account.id=fallback.account_id
  WHERE fallback.account_function_key IN('BANK','CASH_DRAWER','CUSTOMER_RECEIVABLE')
)
SELECT mapping_kind,company_id,company_name,mapping_id,category_name,system_key,
  account_function_key,status,effective_now,effective_from,effective_to,version,
  account_id,account_code,account_name,account_type,account_active,account_postable,
  created_at,updated_at
FROM mapping_versions
ORDER BY company_name,account_function_key,mapping_kind,version DESC,created_at DESC;
