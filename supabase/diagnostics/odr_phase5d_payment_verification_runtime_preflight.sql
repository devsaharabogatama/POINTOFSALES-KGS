-- ODR-5D Sales Payment verification runtime exact preflight.
-- SAFETY: SELECT-only. No Payment, Cash drawer, Event, Queue or Journal mutation.
WITH dependency_versions(version) AS (
  VALUES('20260828210000'::TEXT),('20260828220000'),('20260828230000')
),odr_orders AS (
  SELECT sale.company_id,sale.id sales_id,sale.session_id,sale.store_id,
    sale.customer_id,sale.is_tempo,sale.document_status,
    sale.order_runtime_status,sale.grand_total_after_rounding,
    sale.payload_snapshot,reservation.id reservation_id,
    delivery.id delivery_document_id,delivery.status delivery_status
  FROM public.sales_stock_reservations reservation
  JOIN public.sales_headers sale ON sale.company_id=reservation.company_id
    AND sale.id=reservation.sales_id
  LEFT JOIN public.sales_delivery_documents delivery
    ON delivery.company_id=reservation.company_id
   AND delivery.reservation_id=reservation.id
),payment_intents AS (
  SELECT sale.*,intent.ordinality payment_ordinal,intent.value payment_payload,
    intent.value->>'clientPaymentKey' client_payment_key_text,
    intent.value->>'paymentMethodId' payment_method_id_text,
    intent.value->>'amount' amount_text,
    intent.value->>'tenderedAmount' tendered_amount_text,
    NULLIF(btrim(intent.value->>'proofUrl'),'') proof_url
  FROM odr_orders sale
  CROSS JOIN LATERAL jsonb_array_elements(
    CASE WHEN jsonb_typeof(sale.payload_snapshot->'payments')='array'
      THEN sale.payload_snapshot->'payments' ELSE '[]'::JSONB END
  ) WITH ORDINALITY intent(value,ordinality)
),normalized_intents AS (
  SELECT intent.*,
    CASE WHEN intent.client_payment_key_text~*
      '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      THEN intent.client_payment_key_text::UUID END client_payment_key,
    CASE WHEN intent.payment_method_id_text~*
      '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      THEN intent.payment_method_id_text::UUID END payment_method_id,
    CASE WHEN intent.amount_text~'^([0-9]+)(\.[0-9]+)?$'
      THEN intent.amount_text::NUMERIC END amount,
    CASE WHEN COALESCE(intent.tendered_amount_text,intent.amount_text)~
      '^([0-9]+)(\.[0-9]+)?$'
      THEN COALESCE(intent.tendered_amount_text,intent.amount_text)::NUMERIC
      END tendered_amount
  FROM payment_intents intent
),intent_scope AS (
  SELECT intent.*,method.payment_method_code,method.payment_method_name,
    method.method_type,method.settlement_route,method.proof_mode,
    method.clearing_account_function,method.bank_account_function,
    method.available_all_stores,
    method.fee_enabled,method.fee_bearer,method.fee_type,
    method.fee_percent,method.fee_fixed_amount,method.is_active method_active,
    method.effective_from,method.effective_to,session.status session_status,
    session.pos_id
  FROM normalized_intents intent
  LEFT JOIN public.payment_methods method
    ON method.company_id=intent.company_id AND method.id=intent.payment_method_id
  LEFT JOIN public.cashier_sessions session
    ON session.company_id=intent.company_id AND session.id=intent.session_id
),target_categories AS (
  SELECT company.id company_id,company.company_code,category.id category_id
  FROM public.companies company
  LEFT JOIN public.transaction_categories category
    ON category.company_id=company.id
   AND category.system_key='SALE_PAYMENT_VERIFIED'
   AND category.category_code='ODR-SALE-PAYMENT-VERIFIED'
   AND category.is_active
  WHERE company.status='ACTIVE'
),required_functions(function_key) AS (
  VALUES('CASH_DRAWER'::TEXT),('BANK'),('BANK_RECEIPT'),
    ('PAYMENT_CLEARING'),('CUSTOMER_RECEIVABLE'),
    ('CUSTOMER_ADVANCE_LIABILITY')
),checks AS (
  SELECT 'odr_phase5d_dependencies'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(
      dependency.version ORDER BY dependency.version)
      FILTER(WHERE migration.version IS NULL),'[]'::JSONB)) details
  FROM dependency_versions dependency
  LEFT JOIN private.kgs_schema_migrations migration
    ON migration.version=dependency.version

  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')

  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')

  UNION ALL
  SELECT 'posted_journal_balance',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('journalCount',count(*))
  FROM public.finance_journals journal
  WHERE journal.status='POSTED'
    AND (journal.total_debit<>journal.total_credit OR journal.total_debit<=0)

  UNION ALL
  SELECT 'automatic_posting_remains_closed',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('automaticCompanies',count(*))
  FROM public.finance_company_policies policy
  WHERE policy.posting_mode='AUTOMATIC'

  UNION ALL
  SELECT 'payment_verification_source_schema_contract',
    CASE WHEN count(*)=25 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',25,'columnRows',count(*))
  FROM information_schema.columns column_state
  WHERE column_state.table_schema='public'
    AND column_state.table_name='sales_payment_verification_requests'
    AND column_state.column_name IN('id','company_id','sales_id',
      'client_payment_key','payment_method_id','amount','proof_url','status',
      'receipt_timing','settlement_target','payment_method_code_snapshot',
      'payment_method_name_snapshot','payment_method_type_snapshot',
      'settlement_route_snapshot','settlement_account_function_snapshot',
      'intent_snapshot','financial_event_id','requested_by','requested_at',
      'reviewed_by','reviewed_at','review_note','master_version','created_at',
      'updated_at')

  UNION ALL
  SELECT 'payment_verification_zero_runtime',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('requestRows',count(*))
  FROM public.sales_payment_verification_requests

  UNION ALL
  SELECT 'odr_payment_intent_identity_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidRows',count(*))
  FROM normalized_intents intent
  WHERE jsonb_typeof(intent.payment_payload)<>'object'
    OR intent.client_payment_key IS NULL OR intent.payment_method_id IS NULL
    OR intent.amount IS NULL OR intent.amount<=0
    OR intent.tendered_amount IS NULL OR intent.tendered_amount<intent.amount

  UNION ALL
  SELECT 'odr_payment_intent_duplicate_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicateGroups',count(*))
  FROM (SELECT intent.company_id,intent.sales_id,intent.client_payment_key
    FROM normalized_intents intent WHERE intent.client_payment_key IS NOT NULL
    GROUP BY intent.company_id,intent.sales_id,intent.client_payment_key
    HAVING count(*)>1) duplicate

  UNION ALL
  SELECT 'odr_payment_method_snapshot_readiness',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidRows',count(*))
  FROM intent_scope intent
  WHERE intent.payment_method_id IS NULL OR intent.payment_method_code IS NULL
    OR NOT COALESCE(intent.method_active,FALSE)
    OR intent.effective_from>clock_timestamp()
    OR (intent.effective_to IS NOT NULL
      AND intent.effective_to<clock_timestamp())
    OR intent.method_type='TEMPO' OR intent.settlement_route='RECEIVABLE'
    OR (NOT COALESCE(intent.available_all_stores,FALSE)
      AND NOT EXISTS(SELECT 1
        FROM public.payment_method_store_assignments assignment
        WHERE assignment.company_id=intent.company_id
          AND assignment.payment_method_id=intent.payment_method_id
          AND assignment.store_id=intent.store_id))
    OR (intent.settlement_route='DIRECT_BANK'
      AND NULLIF(btrim(intent.bank_account_function),'') IS NULL)
    OR (intent.settlement_route='CLEARING'
      AND NULLIF(btrim(intent.clearing_account_function),'') IS NULL)

  UNION ALL
  SELECT 'odr_payment_proof_readiness',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidRows',count(*))
  FROM intent_scope intent
  WHERE (intent.proof_mode='REQUIRED' AND intent.proof_url IS NULL)
    OR (intent.proof_url IS NOT NULL AND intent.proof_url!~*'^https://')

  UNION ALL
  SELECT 'odr_payment_total_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('orderCount',count(*))
  FROM (SELECT sale.company_id,sale.sales_id,sale.is_tempo,
      sale.grand_total_after_rounding,COALESCE(sum(intent.amount),0) payment_total
    FROM odr_orders sale LEFT JOIN normalized_intents intent
      ON intent.company_id=sale.company_id AND intent.sales_id=sale.sales_id
    GROUP BY sale.company_id,sale.sales_id,sale.is_tempo,
      sale.grand_total_after_rounding) total
  WHERE (NOT total.is_tempo
      AND total.payment_total<>total.grand_total_after_rounding)
    OR (total.is_tempo
      AND total.payment_total>total.grand_total_after_rounding)

  UNION ALL
  SELECT 'odr_internal_liability_payment_scope',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
    jsonb_build_object('intentRows',count(*),'requiredDesign',jsonb_build_array(
      'Customer Balance payment keeps its own liability-ledger authority',
      'it must not be posted as Cash Bank or Customer Advance',
      'ODR verification may not duplicate the existing Customer Balance debit'))
  FROM intent_scope intent
  WHERE intent.settlement_route='INTERNAL_LIABILITY'

  UNION ALL
  SELECT 'payment_exact_account_mapping',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidRows',count(*))
  FROM target_categories category CROSS JOIN required_functions account_function
  WHERE category.category_id IS NULL OR (SELECT count(*)
    FROM public.transaction_account_rules rule
    JOIN public.chart_of_accounts account ON account.company_id=rule.company_id
      AND account.id=rule.account_id AND account.is_active AND account.is_postable
    WHERE rule.company_id=category.company_id
      AND rule.transaction_category_id=category.category_id
      AND rule.system_key='SALE_PAYMENT_VERIFIED'
      AND rule.account_function_key=account_function.function_key
      AND rule.status='ACTIVE' AND rule.effective_from<=clock_timestamp()
      AND (rule.effective_to IS NULL
        OR rule.effective_to>clock_timestamp()))<>1

  UNION ALL
  SELECT 'payment_approved_posting_rule',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidRows',count(*))
  FROM target_categories category
  WHERE category.category_id IS NULL OR (SELECT count(*)
    FROM public.posting_rule_sets rule_set
    WHERE rule_set.company_id=category.company_id
      AND rule_set.transaction_category_id=category.category_id
      AND rule_set.system_key='SALE_PAYMENT_VERIFIED'
      AND rule_set.status='APPROVED'
      AND rule_set.effective_from<=clock_timestamp()
      AND (rule_set.effective_to IS NULL
        OR rule_set.effective_to>clock_timestamp()))<>1

  UNION ALL
  SELECT 'payment_event_type_compatibility',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('legacyEventType','PAYMENT_RECEIVED','enumRows',count(*))
  FROM pg_type type_state JOIN pg_enum enum_state
    ON enum_state.enumtypid=type_state.oid
  WHERE type_state.typname=(SELECT column_state.udt_name
    FROM information_schema.columns column_state
    WHERE column_state.table_schema='public'
      AND column_state.table_name='financial_events'
      AND column_state.column_name='event_type')
    AND enum_state.enumlabel='PAYMENT_RECEIVED'

  UNION ALL
  SELECT 'payment_verification_permission_state','SETUP',
    jsonb_build_object('rows',count(*),'statuses',COALESCE(jsonb_agg(
      catalog.enforcement_status ORDER BY catalog.enforcement_status),
      '[]'::JSONB),'expectedKey','finance.sales_payment_verification')
  FROM public.access_permission_catalog catalog
  WHERE catalog.permission_key='finance.sales_payment_verification'

  UNION ALL
  SELECT 'canonical_payment_verification_runtime_state','SETUP',
    jsonb_build_object('requiredDesign',jsonb_build_array(
      'server captures immutable request from confirmed Order payment intent',
      'Finance VIEW REVIEW APPROVE POST use guarded composed RPCs',
      'verify and reject are maker-checker exact-retry operations',
      'verified request creates exactly one source-linked HOLD Event',
      'legacy POSTED Sale Payment and Journal remain immutable'))

  UNION ALL
  SELECT 'predispatch_advance_allocation_scope','REVIEW',
    jsonb_build_object('requiredDesign',jsonb_build_array(
      'verified before first Dispatch credits Customer Advance liability',
      'later Dispatch debits only the applied Advance amount',
      'remaining Dispatch settlement stays Clearing or Receivable',
      'partial Dispatch allocation and final residual are exact and idempotent'))

  UNION ALL
  SELECT 'postdispatch_settlement_scope','REVIEW',
    jsonb_build_object('requiredDesign',jsonb_build_array(
      'non TEMPO verified after Dispatch credits Payment Clearing',
      'TEMPO verified after Dispatch credits Customer Receivable',
      'Cash Bank side uses immutable payment method account function snapshot',
      'verification never creates Revenue COGS Stock or a second Dispatch event'))

  UNION ALL
  SELECT 'cash_session_operational_boundary','REVIEW',
    jsonb_build_object('cashIntentRows',count(*),
      'closedSessionCashIntentRows',count(*) FILTER(
        WHERE intent.session_status::TEXT='CLOSED'),
      'requiredDecision',jsonb_build_array(
        'Cash collected by Cashier must enter expected drawer exactly once',
        'Finance verification controls Journal settlement, not physical cash truth',
        'session close and Deposit must not omit or double-count pending Cash'))
  FROM intent_scope intent WHERE intent.settlement_route='CASH_DRAWER'

  UNION ALL
  SELECT 'legacy_sale_payment_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('linkedVerificationRows',count(*))
  FROM public.sales_payment_verification_requests verification
  JOIN public.sales_headers sale ON sale.company_id=verification.company_id
    AND sale.id=verification.sales_id
  WHERE sale.document_status='POSTED'
    AND NOT EXISTS(SELECT 1 FROM public.sales_stock_reservations reservation
      WHERE reservation.company_id=sale.company_id AND reservation.sales_id=sale.id)

  UNION ALL
  SELECT 'odr5d_payment_runtime_inventory','INFO',jsonb_build_object(
    'orders',(SELECT count(*) FROM odr_orders),
    'paymentIntents',(SELECT count(*) FROM payment_intents),
    'cashIntents',(SELECT count(*) FROM intent_scope
      WHERE settlement_route='CASH_DRAWER'),
    'bankIntents',(SELECT count(*) FROM intent_scope
      WHERE settlement_route IN('DIRECT_BANK','CLEARING')),
    'internalLiabilityIntents',(SELECT count(*) FROM intent_scope
      WHERE settlement_route='INTERNAL_LIABILITY'),
    'verificationRequests',(SELECT count(*)
      FROM public.sales_payment_verification_requests),
    'dispatchEffects',(SELECT count(*)
      FROM public.sales_dispatch_financial_effects),
    'legacySalePayments',(SELECT count(*) FROM public.sales_payments),
    'historicalPostedJournals',(SELECT count(*) FROM public.finance_journals
      WHERE status='POSTED'))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1
  WHEN 'REVIEW' THEN 2 WHEN 'SETUP' THEN 3 ELSE 4 END,check_name;
