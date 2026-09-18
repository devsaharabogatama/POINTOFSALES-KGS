-- SELECT-only diagnosis for Customer Receipt COA posting failures.
-- Run the complete file. It does not change Receipt, COA, mapping, or Journal rows.
WITH draft_receipts AS (
  SELECT document.company_id,company.company_name,company.timezone,
    document.id document_id,document.receipt_no,document.receipt_date,
    document.status,document.payment_method_id,
    document.payment_method_name_snapshot,document.settlement_route_snapshot,
    (document.receipt_date::text||' 12:00:00')::timestamp
      AT TIME ZONE company.timezone event_at
  FROM public.customer_receipt_documents document
  JOIN public.companies company ON company.id=document.company_id
  WHERE document.status='DRAFT'
  UNION ALL
  SELECT company.id,company.company_name,company.timezone,
    company.id document_id,'[NO_DRAFT_CURRENT_MAPPING]' receipt_no,
    (clock_timestamp() AT TIME ZONE company.timezone)::date receipt_date,
    'DIAGNOSTIC' status,NULL::uuid payment_method_id,
    'Current DIRECT_BANK mapping' payment_method_name_snapshot,
    'DIRECT_BANK' settlement_route_snapshot,
    clock_timestamp() event_at
  FROM public.companies company
  WHERE company.status='ACTIVE'
    AND NOT EXISTS(SELECT 1 FROM public.customer_receipt_documents document
      WHERE document.company_id=company.id AND document.status='DRAFT')
), required_functions AS (
  SELECT receipt.*,
    CASE receipt.settlement_route_snapshot
      WHEN 'CASH_DRAWER' THEN 'CASH_DRAWER' ELSE 'BANK'
    END account_function_key
  FROM draft_receipts receipt
  UNION ALL
  SELECT receipt.*,'CUSTOMER_RECEIVABLE' account_function_key
  FROM draft_receipts receipt
), category_shape AS (
  SELECT required.company_id,required.document_id,required.account_function_key,
    count(category.id) category_count,
    array_agg(category.id ORDER BY category.id) FILTER(WHERE category.id IS NOT NULL)
      category_ids
  FROM required_functions required
  LEFT JOIN public.transaction_categories category
    ON category.company_id=required.company_id
   AND category.system_key='SALE_PAYMENT' AND category.is_active
  GROUP BY required.company_id,required.document_id,required.account_function_key
), exact_shape AS (
  SELECT required.company_id,required.document_id,required.account_function_key,
    count(rule.id) exact_count,
    array_agg(rule.id ORDER BY rule.rule_version DESC,rule.id)
      FILTER(WHERE rule.id IS NOT NULL) exact_rule_ids,
    array_agg(rule.account_id ORDER BY rule.rule_version DESC,rule.id)
      FILTER(WHERE rule.id IS NOT NULL) exact_account_ids
  FROM required_functions required
  JOIN category_shape category ON category.company_id=required.company_id
    AND category.document_id=required.document_id
    AND category.account_function_key=required.account_function_key
  LEFT JOIN public.transaction_account_rules rule
    ON category.category_count=1
   AND rule.company_id=required.company_id
   AND rule.transaction_category_id=(category.category_ids)[1]
   AND rule.system_key='SALE_PAYMENT'
   AND rule.account_function_key=required.account_function_key
   AND rule.status='ACTIVE' AND rule.effective_from<=required.event_at
   AND (rule.effective_to IS NULL OR rule.effective_to>required.event_at)
  GROUP BY required.company_id,required.document_id,required.account_function_key
), fallback_shape AS (
  SELECT required.company_id,required.document_id,required.account_function_key,
    count(fallback.id) fallback_count,
    array_agg(fallback.id ORDER BY fallback.fallback_version DESC,fallback.id)
      FILTER(WHERE fallback.id IS NOT NULL) fallback_ids,
    array_agg(fallback.account_id ORDER BY fallback.fallback_version DESC,fallback.id)
      FILTER(WHERE fallback.id IS NOT NULL) fallback_account_ids
  FROM required_functions required
  LEFT JOIN public.company_account_function_fallbacks fallback
    ON fallback.company_id=required.company_id
   AND fallback.account_function_key=required.account_function_key
   AND fallback.status='ACTIVE' AND fallback.effective_from<=required.event_at
   AND (fallback.effective_to IS NULL OR fallback.effective_to>required.event_at)
  GROUP BY required.company_id,required.document_id,required.account_function_key
), resolved AS (
  SELECT required.*,category.category_count,category.category_ids,
    exact.exact_count,exact.exact_rule_ids,fallback.fallback_count,fallback.fallback_ids,
    CASE WHEN exact.exact_count=1 THEN (exact.exact_account_ids)[1]
      WHEN exact.exact_count=0 AND fallback.fallback_count=1
        THEN (fallback.fallback_account_ids)[1]
      ELSE NULL END account_id,
    CASE WHEN exact.exact_count=1 THEN 'TRANSACTION_RULE'
      WHEN exact.exact_count=0 AND fallback.fallback_count=1 THEN 'COMPANY_FALLBACK'
      ELSE NULL END mapping_source
  FROM required_functions required
  JOIN category_shape category ON category.company_id=required.company_id
    AND category.document_id=required.document_id
    AND category.account_function_key=required.account_function_key
  JOIN exact_shape exact ON exact.company_id=required.company_id
    AND exact.document_id=required.document_id
    AND exact.account_function_key=required.account_function_key
  JOIN fallback_shape fallback ON fallback.company_id=required.company_id
    AND fallback.document_id=required.document_id
    AND fallback.account_function_key=required.account_function_key
)
SELECT resolved.company_id,resolved.company_name,resolved.document_id,
  resolved.receipt_no,resolved.receipt_date,resolved.payment_method_name_snapshot,
  resolved.settlement_route_snapshot,resolved.account_function_key,
  CASE
    WHEN resolved.category_count<>1 THEN 'BLOCKED_SALE_PAYMENT_CATEGORY'
    WHEN resolved.exact_count>1 THEN 'BLOCKED_EXACT_MAPPING_AMBIGUOUS'
    WHEN resolved.exact_count=0 AND resolved.fallback_count<>1
      THEN 'BLOCKED_FALLBACK_MISSING_OR_AMBIGUOUS'
    WHEN account.id IS NULL THEN 'BLOCKED_ACCOUNT_NOT_FOUND'
    WHEN NOT account.is_active THEN 'BLOCKED_ACCOUNT_INACTIVE'
    WHEN NOT account.is_postable THEN 'BLOCKED_ACCOUNT_NOT_POSTABLE'
    WHEN function_state.function_key IS NULL THEN 'BLOCKED_ACCOUNT_FUNCTION_INACTIVE'
    WHEN NOT (account.account_type=ANY(function_state.compatible_account_types))
      THEN 'BLOCKED_ACCOUNT_TYPE_INCOMPATIBLE'
    ELSE 'PASS'
  END status,
  jsonb_build_object(
    'eventAt',resolved.event_at,'categoryCount',resolved.category_count,
    'categoryIds',COALESCE(to_jsonb(resolved.category_ids),'[]'::jsonb),
    'exactMappingCount',resolved.exact_count,
    'exactRuleIds',COALESCE(to_jsonb(resolved.exact_rule_ids),'[]'::jsonb),
    'fallbackCount',resolved.fallback_count,
    'fallbackIds',COALESCE(to_jsonb(resolved.fallback_ids),'[]'::jsonb),
    'mappingSource',resolved.mapping_source,'accountId',resolved.account_id,
    'accountCode',account.account_code,'accountName',account.account_name,
    'accountType',account.account_type,'accountActive',account.is_active,
    'accountPostable',account.is_postable,
    'compatibleAccountTypes',function_state.compatible_account_types
  ) details
FROM resolved
LEFT JOIN public.chart_of_accounts account ON account.company_id=resolved.company_id
  AND account.id=resolved.account_id
LEFT JOIN public.account_functions function_state
  ON function_state.function_key=resolved.account_function_key
 AND function_state.is_active
ORDER BY CASE WHEN account.id IS NOT NULL AND account.is_active AND account.is_postable
  AND function_state.function_key IS NOT NULL
  AND account.account_type=ANY(function_state.compatible_account_types)
  AND resolved.category_count=1
  AND (resolved.exact_count=1 OR (resolved.exact_count=0 AND resolved.fallback_count=1))
  THEN 1 ELSE 0 END,resolved.company_name,resolved.receipt_no,
  resolved.account_function_key;
