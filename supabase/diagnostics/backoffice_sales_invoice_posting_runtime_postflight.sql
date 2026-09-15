-- SELECT-only verification for 20260909161000.
WITH checks AS (
  SELECT 'migration_ledger'::text check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909161000'
  UNION ALL
  SELECT 'required_invoice_posting_routines',CASE WHEN count(*)=12 THEN 'PASS' ELSE 'FAIL' END,
    abs(12-count(*))::bigint,jsonb_build_object('expected',12,'routineRows',count(*))
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE (namespace.nspname='public' AND proc.proname IN(
      'post_backoffice_sales_invoice','set_backoffice_sales_invoice_down_payments'))
    OR (namespace.nspname='private' AND proc.proname IN(
      'rebuild_backoffice_sales_invoice_dp_applications',
      'require_backoffice_sales_invoice_post_permission',
      'trg_auto_apply_backoffice_sales_invoice_dp',
      'post_backoffice_sales_invoice_financial_event_core',
      'post_financial_event_core_pre_backoffice_invoice',
      'f4b_financial_event_supported_pre_backoffice_invoice',
      'post_financial_event_core','f4b_financial_event_supported',
      'trg_guard_backoffice_sales_dp_application_tax_history',
      'trg_delete_backoffice_sales_dp_application_children'))
  UNION ALL
  SELECT 'dp_application_tax_relation',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*))::bigint,jsonb_build_object('relationRows',count(*))
  FROM information_schema.tables WHERE table_schema='public'
    AND table_name='backoffice_sales_down_payment_application_tax_breakdowns'
  UNION ALL
  SELECT 'dp_application_tax_rls_state',
    CASE WHEN count(*)=1 AND bool_and(class.relrowsecurity) THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(class.relrowsecurity) THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('relationRows',count(*),'rlsEnabled',COALESCE(bool_and(class.relrowsecurity),false))
  FROM pg_class class JOIN pg_namespace namespace ON namespace.oid=class.relnamespace
  WHERE namespace.nspname='public'
    AND class.relname='backoffice_sales_down_payment_application_tax_breakdowns'
  UNION ALL
  SELECT 'dp_application_tax_browser_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants privilege
  WHERE privilege.table_schema='public'
    AND privilege.table_name='backoffice_sales_down_payment_application_tax_breakdowns'
    AND privilege.grantee IN('anon','authenticated')
  UNION ALL
  SELECT 'invoice_operation_contract',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*))::bigint,jsonb_build_object('constraintRows',count(*))
  FROM pg_constraint constraint_state
  WHERE constraint_state.conrelid='public.backoffice_sales_invoice_operations'::regclass
    AND constraint_state.conname='backoffice_sales_invoice_operations_shape_check'
    AND pg_get_constraintdef(constraint_state.oid) LIKE '%SET_DOWN_PAYMENTS%'
    AND pg_get_constraintdef(constraint_state.oid) LIKE '%POST%'
  UNION ALL
  SELECT 'regular_invoice_posting_rule_v2',
    CASE WHEN count(*)>0 AND bool_and(line_count=5 AND debit_tax=1 AND credit_tax=1)
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE line_count<>5 OR debit_tax<>1 OR credit_tax<>1)::bigint,
    jsonb_build_object('approvedSets',count(*),'invalidSets',
      count(*) FILTER(WHERE line_count<>5 OR debit_tax<>1 OR credit_tax<>1))
  FROM (SELECT rule_set.id,count(line.id) line_count,
      count(*) FILTER(WHERE line.account_function_key='OUTPUT_TAX'
        AND line.entry_side='DEBIT'
        AND line.amount_expression_key='BACKOFFICE_INVOICE_DP_TAX_APPLIED') debit_tax,
      count(*) FILTER(WHERE line.account_function_key='OUTPUT_TAX'
        AND line.entry_side='CREDIT'
        AND line.amount_expression_key='BACKOFFICE_INVOICE_CURRENT_OUTPUT_TAX') credit_tax
    FROM public.posting_rule_sets rule_set
    JOIN public.posting_rule_lines line ON line.company_id=rule_set.company_id
      AND line.rule_set_id=rule_set.id
    WHERE rule_set.system_key='BACKOFFICE_SALES_INVOICE' AND rule_set.status='APPROVED'
    GROUP BY rule_set.id) mapped
  UNION ALL
  SELECT 'regular_invoice_posting_rule_lifecycle_audit',
    CASE WHEN count(*)>0 AND bool_and(create_audits=1 AND approve_audits=1)
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE create_audits<>1 OR approve_audits<>1)::bigint,
    jsonb_build_object('approvedSets',count(*),'invalidSets',
      count(*) FILTER(WHERE create_audits<>1 OR approve_audits<>1),
      'requiredLifecycle','DRAFT -> lines -> CREATE audit -> APPROVED -> APPROVE audit')
  FROM (SELECT rule_set.id,
      count(audit.id) FILTER(WHERE audit.action='CREATE') create_audits,
      count(audit.id) FILTER(WHERE audit.action='APPROVE') approve_audits
    FROM public.posting_rule_sets rule_set
    LEFT JOIN public.posting_rule_set_audit audit
      ON audit.company_id=rule_set.company_id AND audit.rule_set_id=rule_set.id
    WHERE rule_set.system_key='BACKOFFICE_SALES_INVOICE'
      AND rule_set.status='APPROVED' AND rule_set.rule_set_version=2
    GROUP BY rule_set.id) lifecycle
  UNION ALL
  SELECT 'regular_invoice_posting_rule_no_draft_residue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('draftRows',count(*))
  FROM public.posting_rule_sets rule_set
  WHERE rule_set.system_key='BACKOFFICE_SALES_INVOICE'
    AND rule_set.status='DRAFT'
  UNION ALL
  SELECT 'regular_invoice_posting_rule_v1_retired',
    CASE WHEN count(*)>0 AND bool_and(rule_set_version=1 AND line_count=4)
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE rule_set_version<>1 OR line_count<>4)::bigint,
    jsonb_build_object('retiredSets',count(*),'invalidSets',
      count(*) FILTER(WHERE rule_set_version<>1 OR line_count<>4))
  FROM (SELECT rule_set.id,rule_set.rule_set_version,count(line.id) line_count
    FROM public.posting_rule_sets rule_set
    JOIN public.posting_rule_lines line ON line.company_id=rule_set.company_id
      AND line.rule_set_id=rule_set.id
    WHERE rule_set.system_key='BACKOFFICE_SALES_INVOICE' AND rule_set.status='RETIRED'
    GROUP BY rule_set.id,rule_set.rule_set_version) retired
  UNION ALL
  SELECT 'invoice_finance_post_permission',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*))::bigint,jsonb_build_object('permissionRows',count(*),
      'enforcementStatus',max(permission.enforcement_status),
      'customizable',COALESCE(bool_and(permission.is_customizable),false),
      'localStrictGuard',true)
  FROM public.access_permission_catalog permission
  WHERE permission.permission_key='finance.journals_reports'
    AND permission.enforcement_status IN('SHADOW','ENFORCED')
    AND permission.is_customizable
    AND 'POST'=ANY(permission.supported_capabilities)
  UNION ALL
  SELECT 'invoice_finance_post_local_guard',
    CASE WHEN count(*)=1
      AND bool_and(position('effectiveCapabilities' in pg_get_functiondef(proc.oid))>0)
      AND bool_and(position('CUSTOM_PERMISSION_DENIED' in pg_get_functiondef(proc.oid))>0)
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1
      AND bool_and(position('effectiveCapabilities' in pg_get_functiondef(proc.oid))>0)
      AND bool_and(position('CUSTOM_PERMISSION_DENIED' in pg_get_functiondef(proc.oid))>0)
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('routineRows',count(*),'scope','Backoffice Invoice Post only')
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE namespace.nspname='private'
    AND proc.proname='require_backoffice_sales_invoice_post_permission'
  UNION ALL
  SELECT 'invoice_posting_rpc_boundary',
    CASE WHEN count(*) FILTER(WHERE grantee='anon')=0
      AND count(*) FILTER(WHERE grantee='authenticated')=2 THEN 'PASS' ELSE 'FAIL' END,
    (count(*) FILTER(WHERE grantee='anon')
      +abs(2-count(*) FILTER(WHERE grantee='authenticated')))::bigint,
    jsonb_build_object('anonExecute',count(*) FILTER(WHERE grantee='anon'),
      'authenticatedExecute',count(*) FILTER(WHERE grantee='authenticated'))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='public' AND privilege.privilege_type='EXECUTE'
    AND privilege.routine_name IN(
      'post_backoffice_sales_invoice','set_backoffice_sales_invoice_down_payments')
    AND privilege.grantee IN('anon','authenticated')
  UNION ALL
  SELECT 'invoice_posting_private_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='private' AND privilege.grantee='authenticated'
    AND privilege.privilege_type='EXECUTE' AND privilege.routine_name IN(
      'rebuild_backoffice_sales_invoice_dp_applications',
      'require_backoffice_sales_invoice_post_permission',
      'trg_auto_apply_backoffice_sales_invoice_dp',
      'post_backoffice_sales_invoice_financial_event_core',
      'post_financial_event_core_pre_backoffice_invoice',
      'f4b_financial_event_supported_pre_backoffice_invoice',
      'post_financial_event_core','f4b_financial_event_supported',
      'trg_guard_backoffice_sales_dp_application_tax_history',
      'trg_delete_backoffice_sales_dp_application_children')
  UNION ALL
  SELECT 'invoice_posting_trigger_contract',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    abs(3-count(*))::bigint,jsonb_build_object('triggerRows',count(*))
  FROM pg_trigger trigger_state
  WHERE NOT trigger_state.tgisinternal AND trigger_state.tgname IN(
    'backoffice_sales_invoice_dp_auto_apply',
    'backoffice_sales_dp_application_tax_history_guard',
    'backoffice_sales_dp_application_delete_children')
  UNION ALL
  SELECT 'invoice_posting_source_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_invoices invoice
  LEFT JOIN public.financial_events event ON event.company_id=invoice.company_id
    AND event.id=invoice.financial_event_id
  LEFT JOIN public.finance_journals journal ON journal.company_id=invoice.company_id
    AND journal.financial_event_id=invoice.financial_event_id
  WHERE invoice.status='POSTED' AND (invoice.invoice_no IS NULL
    OR event.id IS NULL OR event.status::text<>'POSTED'
    OR event.source_table<>'backoffice_sales_invoices' OR event.source_id<>invoice.id
    OR journal.id IS NULL OR journal.status<>'POSTED'
    OR round(journal.total_debit,4)<>round(journal.total_credit,4))
  UNION ALL
  SELECT 'posted_invoice_quantity_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_invoice_quantity_allocations allocation
  JOIN public.backoffice_sales_invoices invoice ON invoice.company_id=allocation.company_id
    AND invoice.id=allocation.invoice_id
  WHERE invoice.status='POSTED' AND allocation.status<>'POSTED'
  UNION ALL
  SELECT 'invoice_posting_runtime_inventory','INFO',0::bigint,jsonb_build_object(
    'draftRegular',(SELECT count(*) FROM public.backoffice_sales_invoices
      WHERE status='DRAFT' AND invoice_type='REGULAR'),
    'draftDownPayment',(SELECT count(*) FROM public.backoffice_sales_invoices
      WHERE status='DRAFT' AND invoice_type='DOWN_PAYMENT'),
    'postedRegular',(SELECT count(*) FROM public.backoffice_sales_invoices
      WHERE status='POSTED' AND invoice_type='REGULAR'),
    'postedDownPayment',(SELECT count(*) FROM public.backoffice_sales_invoices
      WHERE status='POSTED' AND invoice_type='DOWN_PAYMENT'),
    'dpApplications',(SELECT count(*) FROM public.backoffice_sales_down_payment_applications),
    'applicationTaxRows',(SELECT count(*)
      FROM public.backoffice_sales_down_payment_application_tax_breakdowns))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
