-- SELECT-only Fase A production inventory for Backoffice AR Task 5.
-- No DDL, DML, context mutation, temp object, or deployment.
WITH required AS (
  SELECT '20260722120000'::text AS version UNION ALL
  SELECT '20260722150000' UNION ALL SELECT '20260805090000' UNION ALL
  SELECT '20260805130000' UNION ALL SELECT '20260805160000' UNION ALL
  SELECT '20260812120000' UNION ALL SELECT '20260813090000' UNION ALL
  SELECT '20260827120000' UNION ALL SELECT '20260909156000' UNION ALL
  SELECT '20260917150000' UNION ALL SELECT '20260918150000' UNION ALL
  SELECT '20261105100000' UNION ALL SELECT '20261105110000' UNION ALL
  SELECT '20261105120000'
), dependency AS (
  SELECT array_agg(required.version ORDER BY required.version)
      FILTER(WHERE migration.version IS NULL) AS missing,
    array_agg(required.version ORDER BY required.version)
      FILTER(WHERE migration.version IS NOT NULL) AS installed
  FROM required
  LEFT JOIN private.kgs_schema_migrations migration
    ON migration.version=required.version
), candidate_names AS (
  SELECT 'apply_backoffice_ar_open_credit'::text AS name UNION ALL
  SELECT 'refund_backoffice_ar_open_credit' UNION ALL
  SELECT 'convert_backoffice_ar_open_credit_to_customer_balance' UNION ALL
  SELECT 'apply_customer_balance_to_backoffice_invoice' UNION ALL
  SELECT 'reverse_backoffice_ar_open_credit_action'
), required_account_functions AS (
  SELECT 'CUSTOMER_RECEIVABLE'::text AS function_key UNION ALL
  SELECT 'CUSTOMER_BALANCE_LIABILITY' UNION ALL
  SELECT 'CASH_DRAWER' UNION ALL SELECT 'BANK_RECEIPT'
), installation AS (
  SELECT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261106100000') AS ledger,
    (SELECT count(*) FROM pg_proc routine
      JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
      JOIN candidate_names candidate ON candidate.name=routine.proname
      WHERE namespace.nspname IN('public','private')) AS candidate_routines
), routines AS (
  SELECT to_regprocedure('public.get_finance_ar_open_items(uuid,boolean)')
      AS open_items,
    to_regprocedure('private.trg_ar_open_item_validate_allocation()')
      AS allocation_guard,
    to_regprocedure(
      'private.ar4_register_backoffice_credit_note_open_item(uuid,uuid,uuid)')
      AS credit_register,
    to_regprocedure(
      'private.backoffice_invoice_receivable_before_receipts(uuid,uuid,date)')
      AS invoice_receivable,
    to_regprocedure(
      'public.post_backoffice_sales_customer_refund(uuid,bigint,uuid,date,numeric,uuid,text,text,text)')
      AS legacy_refund,
    to_regprocedure(
      'public.reverse_backoffice_sales_customer_refund(uuid,bigint,uuid,date,text)')
      AS legacy_refund_reversal,
    to_regprocedure('private.trg_g4_customer_balance_source_integrity()')
      AS balance_source_guard,
    to_regprocedure(
      'private.resolve_customer_balance_account(uuid,uuid,text,timestamp with time zone)')
      AS balance_account_resolver
), definitions AS (
  SELECT md5(pg_get_functiondef(open_items)) AS open_items_md5,
    md5(pg_get_functiondef(allocation_guard)) AS allocation_guard_md5,
    md5(pg_get_functiondef(credit_register)) AS credit_register_md5,
    md5(pg_get_functiondef(invoice_receivable)) AS invoice_receivable_md5,
    md5(pg_get_functiondef(legacy_refund)) AS legacy_refund_md5,
    md5(pg_get_functiondef(legacy_refund_reversal)) AS legacy_reversal_md5,
    md5(pg_get_functiondef(balance_source_guard)) AS balance_source_guard_md5,
    md5(pg_get_functiondef(balance_account_resolver)) AS balance_resolver_md5,
    pg_get_functiondef(open_items) ILIKE '%ar_open_item_allocations%'
      AND pg_get_functiondef(open_items) NOT ILIKE '%effective_date%'
      AS open_items_pre_task5,
    pg_get_functiondef(allocation_guard) ILIKE '%POST_RECEIPT%'
      AND pg_get_functiondef(allocation_guard) NOT ILIKE '%APPLY_OPEN_CREDIT%'
      AS allocation_guard_pre_task5,
    pg_get_functiondef(credit_register) ~* '''runtime''\s*,\s*''TASK4'''
      AS task4_credit_register,
    pg_get_functiondef(legacy_refund) ILIKE '%CUSTOMER_REFUND_LIABILITY%'
      AND pg_get_functiondef(legacy_refund) ILIKE
        '%CUSTOMER_REFUND_CREDIT_NOTE_NOT_ELIGIBLE%'
      AND pg_get_functiondef(legacy_refund) ILIKE '%refund_liability_amount%'
      AS liability_refund_runtime,
    pg_get_functiondef(balance_source_guard) ILIKE '%CUSTOMER_RECEIPT%'
      AND pg_get_functiondef(balance_source_guard) NOT ILIKE
        '%OPEN_CREDIT_CONVERSION%'
      AND pg_get_functiondef(balance_source_guard) NOT ILIKE
        '%BACKOFFICE_INVOICE_PAYMENT%'
      AS balance_guard_pre_task5
  FROM routines
), constraints AS (
  SELECT
    (SELECT pg_get_constraintdef(oid) FROM pg_constraint
      WHERE conrelid='public.ar_open_item_operations'::regclass
        AND conname='ar_open_item_operations_shape') AS operation_shape,
    (SELECT pg_get_constraintdef(oid) FROM pg_constraint
      WHERE conrelid='public.ar_open_item_allocations'::regclass
        AND conname='ar_open_item_allocations_shape') AS allocation_shape,
    (SELECT pg_get_constraintdef(oid) FROM pg_constraint
      WHERE conrelid='public.ar_open_item_registry'::regclass
        AND conname='ar_open_item_registry_shape') AS registry_shape,
    (SELECT pg_get_constraintdef(oid) FROM pg_constraint
      WHERE conrelid='public.customer_balance_ledger_entries'::regclass
        AND conname='customer_balance_ledger_source_check') AS balance_source_shape,
    (SELECT pg_get_constraintdef(oid) FROM pg_constraint
      WHERE conrelid='public.backoffice_sales_customer_refunds'::regclass
        AND conname='backoffice_sales_customer_refunds_shape_check')
      AS refund_shape
), process_scope AS (
  SELECT company.id AS company_id,company.company_code,company.company_name,
    company.status,setting.active_mode,
    public.private_company_feature_enabled(company.id,'tax_sales_enabled')
      AS tax_sales_enabled,
    public.private_company_feature_enabled(company.id,'customer_balance_enabled')
      AS customer_balance_enabled
  FROM public.companies company
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=company.id
  WHERE setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
), permission_state AS (
  SELECT permission.permission_key,permission.supported_capabilities,
    permission.required_any_features,permission.enforcement_status
  FROM public.access_permission_catalog permission
  WHERE permission.permission_key IN('finance.customer_receipts',
    'finance.customer_refunds','finance.customer_balances')
), credit_items AS (
  SELECT item.company_id,item.id,item.source_id,item.customer_id,
    item.document_no,item.document_date,item.original_amount,
    round(item.original_amount-COALESCE(sum(allocation.allocated_amount),0),4)
      AS residual_amount
  FROM public.ar_open_item_registry item
  JOIN process_scope scope ON scope.company_id=item.company_id
  LEFT JOIN public.ar_open_item_allocations allocation
    ON allocation.company_id=item.company_id
    AND allocation.credit_item_id=item.id
  WHERE item.scope_kind='BACKOFFICE' AND item.item_kind='CREDIT_NOTE'
    AND item.direction='CREDIT'
    AND item.source_snapshot->>'runtime'='TASK4'
  GROUP BY item.company_id,item.id,item.source_id,item.customer_id,
    item.document_no,item.document_date,item.original_amount
), invoice_items AS (
  SELECT item.company_id,item.id,item.source_id,item.customer_id,
    item.document_no,item.document_date,item.original_amount,
    round(item.original_amount-COALESCE(sum(allocation.allocated_amount),0),4)
      AS residual_amount
  FROM public.ar_open_item_registry item
  JOIN process_scope scope ON scope.company_id=item.company_id
  LEFT JOIN public.ar_open_item_allocations allocation
    ON allocation.company_id=item.company_id
    AND allocation.debit_item_id=item.id
  WHERE item.scope_kind='BACKOFFICE' AND item.item_kind='INVOICE'
    AND item.direction='DEBIT'
  GROUP BY item.company_id,item.id,item.source_id,item.customer_id,
    item.document_no,item.document_date,item.original_amount
), allocation_integrity AS (
  SELECT count(*) FILTER(WHERE debit.company_id IS NULL OR credit.company_id IS NULL
      OR debit.customer_id<>credit.customer_id
      OR debit.direction<>'DEBIT' OR credit.direction<>'CREDIT') AS invalid_identity,
    count(*) FILTER(WHERE allocation.reversal_of_allocation_id IS NOT NULL)
      AS reversal_rows
  FROM public.ar_open_item_allocations allocation
  LEFT JOIN public.ar_open_item_registry debit
    ON debit.company_id=allocation.company_id
    AND debit.id=allocation.debit_item_id
  LEFT JOIN public.ar_open_item_registry credit
    ON credit.company_id=allocation.company_id
    AND credit.id=allocation.credit_item_id
), balance_state AS (
  SELECT scope.company_id,scope.company_code,scope.customer_balance_enabled,
    policy.lifecycle_state,
    (SELECT count(*) FROM public.customers customer
      WHERE customer.company_id=scope.company_id
        AND NOT customer.is_system_customer AND customer.current_balance>0)
      AS customers_with_balance,
    (SELECT round(COALESCE(sum(customer.current_balance),0),4)
      FROM public.customers customer
      WHERE customer.company_id=scope.company_id
        AND NOT customer.is_system_customer AND customer.current_balance>0)
      AS total_balance,
    (SELECT count(*) FROM public.payment_methods method
      WHERE method.company_id=scope.company_id AND method.is_active
        AND method.method_type='CUSTOMER_BALANCE') AS active_balance_methods
  FROM process_scope scope
  LEFT JOIN public.customer_balance_company_policies policy
    ON policy.company_id=scope.company_id
), settlement_methods AS (
  SELECT scope.company_id,scope.company_code,
    count(method.id) FILTER(WHERE method.is_active
      AND method.settlement_route='CASH_DRAWER') AS active_cash,
    count(method.id) FILTER(WHERE method.is_active
      AND method.settlement_route='DIRECT_BANK') AS active_direct_bank,
    COALESCE(jsonb_agg(jsonb_build_object('id',method.id,'name',
      method.payment_method_name,'type',method.method_type,'route',
      method.settlement_route,'proofMode',method.proof_mode,
      'bankFunction',method.bank_account_function)
      ORDER BY method.payment_method_name) FILTER(WHERE method.id IS NOT NULL
        AND method.is_active
        AND method.settlement_route IN('CASH_DRAWER','DIRECT_BANK')),
      '[]'::jsonb) AS methods
  FROM process_scope scope
  LEFT JOIN public.payment_methods method ON method.company_id=scope.company_id
  GROUP BY scope.company_id,scope.company_code
), account_inventory AS (
  SELECT scope.company_id,scope.company_code,function_key.function_key,
    count(fallback.id) FILTER(WHERE fallback.status='ACTIVE'
      AND fallback.effective_from<=clock_timestamp()
      AND (fallback.effective_to IS NULL
        OR fallback.effective_to>clock_timestamp())) AS active_fallbacks
  FROM process_scope scope
  CROSS JOIN required_account_functions function_key
  LEFT JOIN public.company_account_function_fallbacks fallback
    ON fallback.company_id=scope.company_id
    AND fallback.account_function_key=function_key.function_key
  GROUP BY scope.company_id,scope.company_code,function_key.function_key
), period_state AS (
  SELECT scope.company_id,scope.company_code,
    count(period.id) FILTER(WHERE period.status IN('OPEN','REOPENED'))
      AS postable_periods
  FROM process_scope scope
  LEFT JOIN public.accounting_periods period ON period.company_id=scope.company_id
  GROUP BY scope.company_id,scope.company_code
), legacy_inventory AS (
  SELECT count(*) AS refund_rows,
    count(*) FILTER(WHERE refund.document_kind='REFUND') AS posted_refunds,
    count(*) FILTER(WHERE refund.document_kind='REVERSAL') AS reversals,
    round(COALESCE(sum(CASE refund.document_kind WHEN 'REFUND' THEN refund.amount
      WHEN 'REVERSAL' THEN -refund.amount ELSE 0 END),0),4) AS net_refunded
  FROM public.backoffice_sales_customer_refunds refund
  JOIN process_scope scope ON scope.company_id=refund.company_id
  WHERE refund.status='POSTED'
), balance_source_inventory AS (
  SELECT entry.source_type,count(*) AS rows,
    round(sum(CASE entry.direction WHEN 'CREDIT' THEN entry.amount
      ELSE -entry.amount END),4) AS net_amount
  FROM public.customer_balance_ledger_entries entry
  JOIN process_scope scope ON scope.company_id=entry.company_id
  GROUP BY entry.source_type
), queue_state AS (
  SELECT (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))
      AS active_finance_queue,
    (SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION'))
      AS nonterminal_offline
)
SELECT 'backoffice_ar_open_credit_actions_preflight_dependency_ledger'
    AS check_name,
  CASE WHEN missing IS NULL THEN 'PASS' ELSE 'BLOCKER' END AS status,
  COALESCE(cardinality(missing),0)::bigint AS violation_rows,
  jsonb_build_object('missing',COALESCE(to_jsonb(missing),'[]'::jsonb),
    'installed',COALESCE(to_jsonb(installed),'[]'::jsonb)) AS details
FROM dependency
UNION ALL
SELECT 'backoffice_ar_open_credit_actions_preflight_installation_state',
  CASE WHEN NOT ledger AND candidate_routines=0 THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN NOT ledger AND candidate_routines=0 THEN 0 ELSE 1 END,
  jsonb_build_object('classification',CASE
    WHEN NOT ledger AND candidate_routines=0 THEN 'NOT_INSTALLED'
    WHEN ledger AND candidate_routines=5 THEN 'INSTALLED_CONSISTENT'
    ELSE 'PARTIAL/INCONSISTENT' END,'ledger',ledger,
    'candidateRoutineRows',candidate_routines)
FROM installation
UNION ALL
SELECT 'backoffice_ar_open_credit_actions_preflight_runtime_anchors',
  CASE WHEN open_items IS NOT NULL AND allocation_guard IS NOT NULL
      AND credit_register IS NOT NULL AND invoice_receivable IS NOT NULL
      AND legacy_refund IS NOT NULL AND legacy_refund_reversal IS NOT NULL
      AND balance_source_guard IS NOT NULL AND balance_account_resolver IS NOT NULL
      AND open_items_pre_task5 AND allocation_guard_pre_task5
      AND task4_credit_register AND liability_refund_runtime
      AND balance_guard_pre_task5 THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN open_items IS NOT NULL AND allocation_guard IS NOT NULL
      AND credit_register IS NOT NULL AND invoice_receivable IS NOT NULL
      AND legacy_refund IS NOT NULL AND legacy_refund_reversal IS NOT NULL
      AND balance_source_guard IS NOT NULL AND balance_account_resolver IS NOT NULL
      AND open_items_pre_task5 AND allocation_guard_pre_task5
      AND task4_credit_register AND liability_refund_runtime
      AND balance_guard_pre_task5 THEN 0 ELSE 1 END,
  jsonb_build_object('openItemsMd5',open_items_md5,
    'allocationGuardMd5',allocation_guard_md5,
    'creditRegisterMd5',credit_register_md5,
    'invoiceReceivableMd5',invoice_receivable_md5,
    'legacyRefundMd5',legacy_refund_md5,
    'legacyReversalMd5',legacy_reversal_md5,
    'balanceSourceGuardMd5',balance_source_guard_md5,
    'balanceResolverMd5',balance_resolver_md5,
    'openItemsPreTask5',open_items_pre_task5,
    'allocationGuardPreTask5',allocation_guard_pre_task5,
    'task4CreditRegister',task4_credit_register,
    'liabilityRefundRuntime',liability_refund_runtime,
    'balanceGuardPreTask5',balance_guard_pre_task5)
FROM routines CROSS JOIN definitions
UNION ALL
SELECT 'backoffice_ar_open_credit_actions_preflight_constraint_contract','INFO',0,
  jsonb_build_object('operationShape',operation_shape,
    'allocationShape',allocation_shape,'registryShape',registry_shape,
    'customerBalanceSourceShape',balance_source_shape,'refundShape',refund_shape)
FROM constraints
UNION ALL
SELECT 'backoffice_ar_open_credit_actions_preflight_process_scope',
  CASE WHEN count(*)>0 AND count(*) FILTER(WHERE status<>'ACTIVE')=0
      AND count(*) FILTER(WHERE tax_sales_enabled)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  count(*) FILTER(WHERE status<>'ACTIVE' OR tax_sales_enabled),
  jsonb_build_object('companies',COALESCE(jsonb_agg(jsonb_build_object(
    'id',company_id,'code',company_code,'name',company_name,'status',status,
    'activeMode',active_mode,'taxSalesEnabled',tax_sales_enabled,
    'customerBalanceEnabled',customer_balance_enabled)
    ORDER BY company_code),'[]'::jsonb))
FROM process_scope
UNION ALL
SELECT 'backoffice_ar_open_credit_actions_preflight_permission_contract',
  CASE WHEN count(*)=3
      AND count(*) FILTER(WHERE enforcement_status='ENFORCED')=3
      AND bool_and('VIEW'=ANY(supported_capabilities))
    THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN count(*)=3 AND count(*) FILTER(WHERE enforcement_status='ENFORCED')=3
      AND bool_and('VIEW'=ANY(supported_capabilities)) THEN 0 ELSE 1 END,
  jsonb_build_object('permissions',COALESCE(jsonb_agg(jsonb_build_object(
    'key',permission_key,'capabilities',supported_capabilities,
    'requiredFeatures',required_any_features,'status',enforcement_status)
    ORDER BY permission_key),'[]'::jsonb))
FROM permission_state
UNION ALL
SELECT 'backoffice_ar_open_credit_actions_preflight_open_credit_inventory','INFO',0,
  jsonb_build_object('rows',count(*),'openRows',count(*) FILTER(WHERE residual_amount>0),
    'totalOriginal',COALESCE(sum(original_amount),0),
    'totalResidual',COALESCE(sum(residual_amount),0),
    'items',COALESCE(jsonb_agg(jsonb_build_object('company',company.company_code,
      'creditItemId',item.id,'creditNoteId',item.source_id,
      'documentNo',item.document_no,'documentDate',item.document_date,
      'customerId',item.customer_id,'original',item.original_amount,
      'residual',item.residual_amount) ORDER BY company.company_code,item.document_no)
      FILTER(WHERE item.residual_amount>0),'[]'::jsonb))
FROM credit_items item JOIN public.companies company ON company.id=item.company_id
UNION ALL
SELECT 'backoffice_ar_open_credit_actions_preflight_invoice_inventory','INFO',0,
  jsonb_build_object('rows',count(*),'openRows',count(*) FILTER(WHERE residual_amount>0),
    'totalResidual',COALESCE(sum(residual_amount),0))
FROM invoice_items
UNION ALL
SELECT 'backoffice_ar_open_credit_actions_preflight_allocation_integrity',
  CASE WHEN invalid_identity=0 AND reversal_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
  invalid_identity+reversal_rows,
  jsonb_build_object('invalidIdentityRows',invalid_identity,
    'existingReversalRows',reversal_rows)
FROM allocation_integrity
UNION ALL
SELECT 'backoffice_ar_open_credit_actions_preflight_customer_balance_state','INFO',0,
  jsonb_build_object('companies',COALESCE(jsonb_agg(jsonb_build_object(
    'code',company_code,'featureEnabled',customer_balance_enabled,
    'lifecycleState',lifecycle_state,'customersWithBalance',customers_with_balance,
    'totalBalance',total_balance,'activeSystemMethods',active_balance_methods)
    ORDER BY company_code),'[]'::jsonb))
FROM balance_state
UNION ALL
SELECT 'backoffice_ar_open_credit_actions_preflight_settlement_methods','INFO',0,
  jsonb_build_object('companies',COALESCE(jsonb_agg(jsonb_build_object(
    'code',company_code,'activeCash',active_cash,
    'activeDirectBank',active_direct_bank,'methods',methods)
    ORDER BY company_code),'[]'::jsonb))
FROM settlement_methods
UNION ALL
SELECT 'backoffice_ar_open_credit_actions_preflight_account_inventory','INFO',0,
  jsonb_build_object('rows',COALESCE(jsonb_agg(jsonb_build_object(
    'company',company_code,'function',function_key,
    'activeFallbacks',active_fallbacks)
    ORDER BY company_code,function_key),'[]'::jsonb))
FROM account_inventory
UNION ALL
SELECT 'backoffice_ar_open_credit_actions_preflight_period_contract',
  CASE WHEN count(*) FILTER(WHERE postable_periods=0)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  count(*) FILTER(WHERE postable_periods=0),
  jsonb_build_object('companies',COALESCE(jsonb_agg(jsonb_build_object(
    'code',company_code,'postablePeriods',postable_periods)
    ORDER BY company_code),'[]'::jsonb))
FROM period_state
UNION ALL
SELECT 'backoffice_ar_open_credit_actions_preflight_legacy_refund_inventory','INFO',0,
  jsonb_build_object('rows',refund_rows,'postedRefunds',posted_refunds,
    'reversals',reversals,'netRefunded',net_refunded)
FROM legacy_inventory
UNION ALL
SELECT 'backoffice_ar_open_credit_actions_preflight_balance_source_inventory','INFO',0,
  jsonb_build_object('sources',COALESCE(jsonb_agg(jsonb_build_object(
    'sourceType',source_type,'rows',rows,'netAmount',net_amount)
    ORDER BY source_type),'[]'::jsonb))
FROM balance_source_inventory
UNION ALL
SELECT 'backoffice_ar_open_credit_actions_preflight_runtime_boundary',
  CASE WHEN active_finance_queue=0 AND nonterminal_offline=0
    THEN 'PASS' ELSE 'BLOCKER' END,
  active_finance_queue+nonterminal_offline,
  jsonb_build_object('activeFinanceQueue',active_finance_queue,
    'nonterminalOffline',nonterminal_offline)
FROM queue_state
UNION ALL
SELECT 'backoffice_ar_open_credit_actions_preflight_business_boundary','INFO',0,
  jsonb_build_object('mutation','NONE','planned',jsonb_build_array(
      'direct Credit Note apply to Posted Backoffice Invoice',
      'AR-native Cash or Bank refund',
      'explicit Credit Note conversion to Customer Balance',
      'Customer Balance settlement of Posted Backoffice Invoice',
      'append-only reversal and effective-date allocation'),
    'singleActor','authorized Finance actor posts directly; no new maker-checker',
    'preserved',jsonb_build_array('SO and Draft Invoice cannot use Customer Balance',
      'POS Retail','Stock Reservation FIFO HPP','Customer Receipt journal',
      'legacy Refund Liability and RETAINED_RETAIL','manual balance correction maker-checker',
      'historical Posted documents and Journals','price correction'),
    'next','Return every row. Any BLOCKER or unexpected drift freezes Phase B.');
