-- SELECT-only preflight for 20260909161000 on isolated Development only.
WITH invoice_reconciliation AS (
  SELECT invoice.company_id,invoice.id,invoice.status,invoice.invoice_type,
    invoice.charge_total,invoice.discount_total,invoice.tax_total,invoice.grand_total,
    COALESCE(sum(line.line_amount) FILTER(WHERE line.effect_type='CHARGE'),0) line_charge,
    COALESCE(sum(line.discount_amount) FILTER(WHERE line.effect_type='CHARGE'),0) line_discount,
    COALESCE(sum(line.tax_amount) FILTER(WHERE line.effect_type='CHARGE'),0) line_tax,
    COALESCE(sum(line.line_amount) FILTER(WHERE line.effect_type='DEDUCTION'),0) line_deduction,
    COALESCE((SELECT sum(schedule.amount_due)
      FROM public.backoffice_sales_invoice_receivable_schedules schedule
      WHERE schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id),0) schedule_total
  FROM public.backoffice_sales_invoices invoice
  LEFT JOIN public.backoffice_sales_invoice_lines line
    ON line.company_id=invoice.company_id AND line.invoice_id=invoice.id
  GROUP BY invoice.company_id,invoice.id,invoice.status,invoice.invoice_type,
    invoice.charge_total,invoice.discount_total,invoice.tax_total,invoice.grand_total
), behavior_fixture_companies AS (
  SELECT company.id
  FROM public.companies company
  WHERE company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.stores store
      JOIN public.warehouses warehouse ON warehouse.company_id=store.company_id
        AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
      WHERE store.company_id=company.id AND store.status='ACTIVE'
        AND warehouse.is_active AND warehouse.is_sale_source)
    AND EXISTS(SELECT 1 FROM public.customers customer
      WHERE customer.company_id=company.id AND customer.is_active)
    AND EXISTS(SELECT 1 FROM public.product_uoms product_uom
      JOIN public.products product ON product.company_id=product_uom.company_id
        AND product.id=product_uom.product_id AND product.is_active AND NOT product.is_bundle
      WHERE product_uom.company_id=company.id AND product_uom.is_active
        AND product_uom.sales_allowed AND product_uom.factor_to_base>0)
    AND EXISTS(SELECT 1 FROM public.accounting_periods period
      WHERE period.company_id=company.id AND period.status IN('OPEN','REOPENED')
        AND current_date BETWEEN period.start_date AND period.end_date)
), checks AS (
  SELECT 'required_invoice_gate_chain'::text check_name,
    CASE WHEN count(*)=5 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(5-count(*))::bigint violation_rows,
    jsonb_build_object('expected',5,'ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version IN(
    '20260909156000','20260909157000','20260909158000','20260909159000','20260909160000')
  UNION ALL
  SELECT 'target_migration_ledger_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('targetLedgerRows',count(*),
      'expected',0,'provesFailedRunRolledBack',count(*)=0)
  FROM private.kgs_schema_migrations WHERE version='20260909161000'
  UNION ALL
  SELECT 'active_finance_posting_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'migration_actor_dependency',CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('linkedSuperAdmins',count(*))
  FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role::text='super_admin'
  UNION ALL
  SELECT 'nonterminal_offline_submission',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'invoice_posting_identity_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('collisionRows',count(*))
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
      'trg_guard_backoffice_sales_dp_application_tax_history',
      'trg_delete_backoffice_sales_dp_application_children'))
  UNION ALL
  SELECT 'dp_application_tax_relation_boundary',
    CASE WHEN to_regclass('public.backoffice_sales_down_payment_application_tax_breakdowns')
      IS NULL THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN to_regclass('public.backoffice_sales_down_payment_application_tax_breakdowns')
      IS NULL THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('relationExists',to_regclass(
      'public.backoffice_sales_down_payment_application_tax_breakdowns') IS NOT NULL)
  UNION ALL
  SELECT 'finance_post_permission_contract',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(1-count(*))::bigint,jsonb_build_object('permissionRows',count(*),
      'enforcementStatus',max(permission.enforcement_status),
      'customizable',COALESCE(bool_and(permission.is_customizable),false),
      'rule','Invoice posting enforces resolved POST locally; global Finance status is unchanged')
  FROM public.access_permission_catalog permission
  WHERE permission.permission_key='finance.journals_reports'
    AND permission.enforcement_status IN('SHADOW','ENFORCED')
    AND permission.is_customizable
    AND 'POST'=ANY(permission.supported_capabilities)
  UNION ALL
  SELECT 'posting_rule_lifecycle_dependency',
    CASE WHEN count(*)=2
      AND bool_and(CASE WHEN proc.proname='trg_g6_guard_posting_rule_set'
        THEN position('POSTING_RULE_SET_MUST_START_DRAFT' in pg_get_functiondef(proc.oid))>0
        ELSE position('APPROVED_POSTING_RULE_LINES_IMMUTABLE' in pg_get_functiondef(proc.oid))>0 END)
      AND (SELECT count(*) FROM pg_trigger trigger_state
        WHERE NOT trigger_state.tgisinternal AND trigger_state.tgenabled<>'D'
          AND ((trigger_state.tgrelid='public.posting_rule_sets'::regclass
              AND trigger_state.tgname='g6_guard_posting_rule_set')
            OR (trigger_state.tgrelid='public.posting_rule_lines'::regclass
              AND trigger_state.tgname='g6_guard_posting_rule_line')))=2
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)=2
      AND bool_and(CASE WHEN proc.proname='trg_g6_guard_posting_rule_set'
        THEN position('POSTING_RULE_SET_MUST_START_DRAFT' in pg_get_functiondef(proc.oid))>0
        ELSE position('APPROVED_POSTING_RULE_LINES_IMMUTABLE' in pg_get_functiondef(proc.oid))>0 END)
      AND (SELECT count(*) FROM pg_trigger trigger_state
        WHERE NOT trigger_state.tgisinternal AND trigger_state.tgenabled<>'D'
          AND ((trigger_state.tgrelid='public.posting_rule_sets'::regclass
              AND trigger_state.tgname='g6_guard_posting_rule_set')
            OR (trigger_state.tgrelid='public.posting_rule_lines'::regclass
              AND trigger_state.tgname='g6_guard_posting_rule_line')))=2
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('routineRows',count(*),'requiredTriggerRows',2,
      'enabledTriggerRows',(SELECT count(*) FROM pg_trigger trigger_state
        WHERE NOT trigger_state.tgisinternal AND trigger_state.tgenabled<>'D'
          AND ((trigger_state.tgrelid='public.posting_rule_sets'::regclass
              AND trigger_state.tgname='g6_guard_posting_rule_set')
            OR (trigger_state.tgrelid='public.posting_rule_lines'::regclass
              AND trigger_state.tgname='g6_guard_posting_rule_line'))),
      'requiredLifecycle','DRAFT -> lines -> CREATE audit -> APPROVED -> APPROVE audit')
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE namespace.nspname='private'
    AND proc.proname IN('trg_g6_guard_posting_rule_set','trg_g6_guard_posting_rule_line')
  UNION ALL
  SELECT 'regular_posting_rule_v1_contract',CASE WHEN count(*)>0
      AND bool_and(rule_set_version=1 AND line_count=4)
      AND bool_and(approved_count=1) THEN 'PASS' ELSE 'BLOCKER' END,
    count(*) FILTER(WHERE rule_set_version<>1 OR line_count<>4 OR approved_count<>1)::bigint,
    jsonb_build_object('approvedSets',count(*),'invalidSets',
      count(*) FILTER(WHERE rule_set_version<>1 OR line_count<>4 OR approved_count<>1))
  FROM (SELECT rule_set.id,rule_set.rule_set_version,count(line.id) line_count,
      count(*) OVER(PARTITION BY rule_set.company_id,rule_set.transaction_category_id) approved_count
    FROM public.posting_rule_sets rule_set
    JOIN public.posting_rule_lines line ON line.company_id=rule_set.company_id
      AND line.rule_set_id=rule_set.id
    WHERE rule_set.system_key='BACKOFFICE_SALES_INVOICE' AND rule_set.status='APPROVED'
    GROUP BY rule_set.id,rule_set.company_id,rule_set.transaction_category_id,
      rule_set.rule_set_version) mapped
  UNION ALL
  SELECT 'dp_posting_rule_contract',CASE WHEN count(*)>0
      AND bool_and(line_count=3) THEN 'PASS' ELSE 'BLOCKER' END,
    count(*) FILTER(WHERE line_count<>3)::bigint,
    jsonb_build_object('approvedSets',count(*),'invalidSets',count(*) FILTER(WHERE line_count<>3))
  FROM (SELECT rule_set.id,count(line.id) line_count
    FROM public.posting_rule_sets rule_set
    JOIN public.posting_rule_lines line ON line.company_id=rule_set.company_id
      AND line.rule_set_id=rule_set.id
    WHERE rule_set.system_key='BACKOFFICE_SALES_DOWN_PAYMENT' AND rule_set.status='APPROVED'
    GROUP BY rule_set.id) mapped
  UNION ALL
  SELECT 'draft_invoice_amount_schedule_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM invoice_reconciliation WHERE status='DRAFT' AND (
    round(charge_total,4)<>round(line_charge+line_discount,4)
    OR round(discount_total,4)<>round(line_discount,4)
    OR round(tax_total,4)<>round(line_tax,4)
    OR round(grand_total,4)<>round(line_charge+line_tax-line_deduction,4)
    OR round(grand_total,4)<>round(schedule_total,4))
  UNION ALL
  SELECT 'invoice_tax_breakdown_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_invoices invoice
  WHERE round(invoice.tax_total,4)<>round(COALESCE((SELECT sum(breakdown.tax_amount)
    FROM public.backoffice_sales_invoice_tax_breakdowns breakdown
    WHERE breakdown.company_id=invoice.company_id AND breakdown.invoice_id=invoice.id),0),4)
  UNION ALL
  SELECT 'pre_posting_runtime_state',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('unexpectedFinalRows',count(*))
  FROM public.backoffice_sales_invoices invoice WHERE invoice.status IN('POSTED','REVERSED')
    OR invoice.invoice_no IS NOT NULL OR invoice.financial_event_id IS NOT NULL
    OR invoice.posted_at IS NOT NULL OR invoice.posted_by IS NOT NULL
  UNION ALL
  SELECT 'behavior_fixture_company',CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint,jsonb_build_object(
    'eligibleCompanies',count(*),
    'draftInvoices',(SELECT count(*) FROM public.backoffice_sales_invoices WHERE status='DRAFT'),
    'draftDatesWithoutOpenPeriod',(SELECT count(*) FROM public.backoffice_sales_invoices invoice
      WHERE invoice.status='DRAFT' AND NOT EXISTS(SELECT 1 FROM public.accounting_periods period
        WHERE period.company_id=invoice.company_id
          AND invoice.invoice_date BETWEEN period.start_date AND period.end_date
          AND period.status IN('OPEN','REOPENED'))),
    'openPeriodsForBehaviorDate',(SELECT count(*) FROM public.accounting_periods period
      WHERE period.status IN('OPEN','REOPENED')
        AND current_date BETWEEN period.start_date AND period.end_date),
    'requiredForBehaviorDate',current_date)
  FROM behavior_fixture_companies
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
