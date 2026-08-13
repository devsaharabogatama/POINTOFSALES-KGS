-- ACP-6G preflight: Payment Method permission cutover readiness.
-- SAFETY: SELECT-only; aggregate metadata only. No account number, payment
-- proof, transaction reference, Customer, Supplier, or user payload returned.

WITH expected_relations(relation_name) AS (VALUES
  ('payment_methods'),('payment_method_store_assignments'),
  ('payment_method_master_audit')
), save_routines AS (
  SELECT procedure.oid,procedure.proname,
    pg_get_function_identity_arguments(procedure.oid) arguments,
    pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND procedure.proname='save_payment_method'
), relation_privileges AS (
  SELECT relation_name,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'SELECT') readable,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'INSERT,UPDATE,DELETE') writable
  FROM expected_relations
), checks AS (
  SELECT 'acp_phase6g_dependencies'::TEXT check_name,
    CASE WHEN count(ledger.version)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',1,'missing',COALESCE(jsonb_agg(required.version)
      FILTER(WHERE ledger.version IS NULL),'[]'::JSONB)) details
  FROM (VALUES('20260813120000')) required(version)
  LEFT JOIN private.kgs_schema_migrations ledger USING(version)

  UNION ALL SELECT 'payment_method_permission_catalog_state',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='SHADOW')
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB),'capabilities',COALESCE(
      jsonb_agg(supported_capabilities),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='finance.payment_methods'

  UNION ALL SELECT 'canonical_payment_method_schema_state',
    CASE WHEN count(*) FILTER(WHERE to_regclass(
      format('public.%I',relation_name)) IS NULL)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(relation_name) FILTER(WHERE to_regclass(
        format('public.%I',relation_name)) IS NULL),'[]'::JSONB))
  FROM expected_relations

  UNION ALL SELECT 'canonical_payment_method_mutation_routine_state',
    CASE WHEN count(*)>=2 AND count(*) FILTER(WHERE
      has_function_privilege('authenticated',oid,'EXECUTE'))>=2
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routine_rows',count(*),'authenticated_rows',count(*)
      FILTER(WHERE has_function_privilege('authenticated',oid,'EXECUTE')),
      'signatures',COALESCE(jsonb_agg(arguments ORDER BY arguments),'[]'::JSONB))
  FROM save_routines

  UNION ALL SELECT 'payment_method_runtime_permission_hook_state','SETUP',
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'))
  FROM save_routines

  UNION ALL SELECT 'canonical_payment_method_composed_read_state','SETUP',
    jsonb_build_object('rpc_exists',to_regprocedure(
      'public.get_finance_payment_methods()') IS NOT NULL,
      'required_design',jsonb_build_array(
        'guard Backoffice list/detail with finance.payment_methods VIEW',
        'return method, Store assignment, fee/route and immutable audit proof only',
        'include narrow Store and active Account Function labels',
        'do not expose Sale, Payment, Expense, drawer or Journal ledgers'))

  UNION ALL SELECT 'payment_method_direct_read_cutover_scope','REVIEW',
    jsonb_build_object('authenticated_read_relations',COALESCE(jsonb_agg(
      relation_name ORDER BY relation_name) FILTER(WHERE readable),'[]'::JSONB),
      'required_design',jsonb_build_array(
        'replace Backoffice dedicated-table reads with one VIEW-guarded composed RPC',
        'replace POS and Expense direct reads with separately authorized narrow RPCs',
        'revoke direct SELECT only after every active consumer migrates'))
  FROM relation_privileges

  UNION ALL SELECT 'payment_method_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE writable)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('direct_write_relations',COALESCE(jsonb_agg(
      relation_name ORDER BY relation_name) FILTER(WHERE writable),'[]'::JSONB))
  FROM relation_privileges

  UNION ALL SELECT 'payment_method_authority_split','REVIEW',
    jsonb_build_object(
      'view_roles',jsonb_build_array('COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'),
      'management_roles',jsonb_build_array('COMPANY_OWNER','COMPANY_ADMIN','FINANCE'),
      'required_design',jsonb_build_array(
        'VIEW grants Backoffice list and detail only',
        'MANAGE mutates ordinary method identity, Store scope, route, proof and fee',
        'system-owned Customer Balance or Ketul Offset remains module-workflow only',
        'EXPORT never follows VIEW implicitly',
        'custom restriction may reduce but never widen Company or Finance role scope'))

  UNION ALL SELECT 'payment_method_pos_consumer_scope','REVIEW',
    jsonb_build_object('required_design',jsonb_build_array(
      'online POS eligibility requires its own active open Cashier session and Store scope',
      'offline catalog remains guarded by Offline entitlement and Terminal policy',
      'server remains authoritative for route, proof, fee and payment snapshots',
      'POS never inherits finance.payment_methods VIEW or MANAGE'))

  UNION ALL SELECT 'payment_method_expense_consumer_scope','REVIEW',
    jsonb_build_object('required_design',jsonb_build_array(
      'Expense receives only active Store-eligible payment references under finance.expenses authority',
      'Expense proof and settlement route are revalidated at final disbursement or return',
      'Expense never inherits finance.payment_methods MANAGE',
      'client-supplied purpose never bypasses either permission key'))

  UNION ALL SELECT 'payment_method_supplier_payment_boundary','REVIEW',
    jsonb_build_object('current_supplier_payment_contract',
      jsonb_build_array('CASH','BANK_TRANSFER','CHEQUE'),
      'required_design',jsonb_build_array(
        'Supplier Payment source-account contract remains independent in ACP-6F',
        'ACP-6G does not silently replace Supplier Payment enum with POS payment-method identity',
        'future unification requires a separate data and Finance compatibility decision'))

  UNION ALL SELECT 'payment_method_export_import_contract','SETUP',
    jsonb_build_object(
      'application_catalog_export_present',FALSE,
      'fixed_csv_contract_present',TRUE,
      'required_design',jsonb_build_array(
        'Payment Method export requires finance.payment_methods EXPORT',
        'ordinary-method import requires an explicit IMPORT capability decision before opening',
        'Customer Balance and Ketul Offset remain export-only system-owned rows',
        'generic import must never mutate Sale, Expense, AP, drawer or Journal history'))

  UNION ALL SELECT 'active_company_default_payment_method_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('company_count',count(*))
  FROM public.companies company
  WHERE company.status='ACTIVE' AND (SELECT count(*)
    FROM public.payment_methods method
    WHERE method.company_id=company.id AND method.is_active
      AND method.is_default)<>1

  UNION ALL SELECT 'active_store_payment_method_readiness',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('store_count',count(*))
  FROM public.stores store
  JOIN public.companies company ON company.id=store.company_id
    AND company.status='ACTIVE'
  WHERE store.status='ACTIVE' AND NOT EXISTS(SELECT 1
    FROM public.payment_methods method
    WHERE method.company_id=store.company_id AND method.is_active
      AND method.effective_from<=clock_timestamp()
      AND (method.effective_to IS NULL OR method.effective_to>=clock_timestamp())
      AND (method.available_all_stores OR EXISTS(SELECT 1
        FROM public.payment_method_store_assignments assignment
        WHERE assignment.company_id=method.company_id
          AND assignment.payment_method_id=method.id
          AND assignment.store_id=store.id)))

  UNION ALL SELECT 'invalid_payment_method_store_scope',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.payment_method_store_assignments assignment
  JOIN public.payment_methods method
    ON method.company_id=assignment.company_id
   AND method.id=assignment.payment_method_id
  JOIN public.stores store ON store.company_id=assignment.company_id
    AND store.id=assignment.store_id
  WHERE method.available_all_stores

  UNION ALL SELECT 'scoped_payment_method_without_store',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('method_count',count(*))
  FROM public.payment_methods method
  WHERE method.is_active AND NOT method.available_all_stores
    AND NOT EXISTS(SELECT 1 FROM public.payment_method_store_assignments assignment
      WHERE assignment.company_id=method.company_id
        AND assignment.payment_method_id=method.id)

  UNION ALL SELECT 'duplicate_normalized_payment_method_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicate_groups',count(*))
  FROM (SELECT company_id,lower(regexp_replace(
      btrim(payment_method_name),'\s+',' ','g')) normalized_name
    FROM public.payment_methods GROUP BY company_id,normalized_name
    HAVING count(*)>1) duplicate

  UNION ALL SELECT 'invalid_payment_method_account_function',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.payment_methods method
  LEFT JOIN public.account_functions clearing_function
    ON clearing_function.function_key=method.clearing_account_function
  LEFT JOIN public.account_functions bank_function
    ON bank_function.function_key=method.bank_account_function
  WHERE (method.settlement_route='CLEARING' AND (
      clearing_function.function_key IS NULL OR NOT clearing_function.is_active))
    OR (method.settlement_route='DIRECT_BANK' AND (
      bank_function.function_key IS NULL OR NOT bank_function.is_active))

  UNION ALL SELECT 'invalid_system_payment_method_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.payment_methods method
  WHERE (method.is_system_method AND (
      method.method_type NOT IN('CUSTOMER_BALANCE','KETUL_OFFSET')
      OR method.settlement_route<>'INTERNAL_LIABILITY'))
    OR (NOT method.is_system_method AND (
      method.method_type IN('CUSTOMER_BALANCE','KETUL_OFFSET')
      OR method.settlement_route='INTERNAL_LIABILITY'))

  UNION ALL SELECT 'multiple_internal_payment_method_per_company',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicate_groups',count(*))
  FROM (SELECT company_id,method_type FROM public.payment_methods
    WHERE method_type IN('CUSTOMER_BALANCE','KETUL_OFFSET')
    GROUP BY company_id,method_type HAVING count(*)>1) duplicate

  UNION ALL SELECT 'payment_method_sales_snapshot_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('payment_count',count(*))
  FROM public.sales_payments payment
  WHERE payment.payment_method_id IS NOT NULL AND (
    btrim(COALESCE(payment.payment_method_code_snapshot,''))=''
    OR btrim(COALESCE(payment.payment_method_name_snapshot,''))=''
    OR btrim(COALESCE(payment.payment_method_type_snapshot,''))=''
    OR btrim(COALESCE(payment.settlement_route_snapshot,''))='')

  UNION ALL SELECT 'payment_method_audit_backfill_scope',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BACKFILL' END,
    jsonb_build_object('method_count',count(*))
  FROM public.payment_methods method
  WHERE NOT EXISTS(SELECT 1 FROM public.payment_method_master_audit audit
    WHERE audit.company_id=method.company_id
      AND audit.payment_method_id=method.id)

  UNION ALL SELECT 'payment_method_override_tenant_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.user_company_permission_overrides override_row
  LEFT JOIN public.company_memberships membership
    ON membership.company_id=override_row.company_id
   AND membership.user_id=override_row.user_id
   AND membership.status='ACTIVE'
  WHERE override_row.permission_key='finance.payment_methods'
    AND membership.user_id IS NULL

  UNION ALL SELECT 'payment_method_runtime_inventory','INFO',
    jsonb_build_object(
      'companies',count(DISTINCT method.company_id),
      'methods',count(*),'active_methods',count(*) FILTER(WHERE method.is_active),
      'system_methods',count(*) FILTER(WHERE method.is_system_method),
      'store_assignments',(SELECT count(*)
        FROM public.payment_method_store_assignments),
      'sales_payment_rows',(SELECT count(*) FROM public.sales_payments),
      'expense_document_rows',(SELECT count(*) FROM public.expense_documents),
      'override_rows',(SELECT count(*)
        FROM public.user_company_permission_overrides override_row
        WHERE override_row.permission_key='finance.payment_methods'))
  FROM public.payment_methods method
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'BACKFILL' THEN 2
  WHEN 'PASS' THEN 3 WHEN 'REVIEW' THEN 4 WHEN 'SETUP' THEN 5 ELSE 6 END,
  check_name;
