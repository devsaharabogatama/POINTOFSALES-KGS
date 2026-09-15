-- Read-only preflight for 20260910150000 on isolated Development.
WITH required_versions(version) AS (VALUES
  ('20260909140000'),('20260909161000'),('20260910140000')
), delivery_sources AS (
  SELECT category.company_id,rule.account_id,
    CASE rule.system_key WHEN 'SALE_POSTED' THEN 1 ELSE 2 END priority
  FROM public.transaction_account_rules rule
  JOIN public.transaction_categories category ON category.company_id=rule.company_id
    AND category.id=rule.transaction_category_id AND category.is_active
  JOIN public.chart_of_accounts account ON account.company_id=rule.company_id
    AND account.id=rule.account_id AND account.is_active AND account.is_postable
  WHERE rule.system_key IN('SALE_POSTED','SALE_DISPATCHED')
    AND category.system_key=rule.system_key
    AND rule.account_function_key='DELIVERY_FEE_REVENUE'
    AND rule.status='ACTIVE' AND rule.effective_from<=clock_timestamp()
    AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())
  UNION ALL
  SELECT fallback.company_id,fallback.account_id,3
  FROM public.company_account_function_fallbacks fallback
  JOIN public.chart_of_accounts account ON account.company_id=fallback.company_id
    AND account.id=fallback.account_id AND account.is_active AND account.is_postable
  WHERE fallback.account_function_key='DELIVERY_FEE_REVENUE'
    AND fallback.status='ACTIVE' AND fallback.effective_from<=clock_timestamp()
    AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp())
  UNION ALL
  SELECT account.company_id,account.id,4 FROM public.chart_of_accounts account
  WHERE account.is_system_account AND account.system_function_key='DELIVERY_FEE_REVENUE'
    AND account.is_active AND account.is_postable
), resolved_sources AS (
  SELECT source.company_id,count(DISTINCT source.account_id) account_count
  FROM delivery_sources source
  WHERE source.priority=(SELECT min(candidate.priority) FROM delivery_sources candidate
    WHERE candidate.company_id=source.company_id)
  GROUP BY source.company_id
), runtime_definitions AS (
  SELECT
    pg_get_functiondef(to_regprocedure(
      'public.post_backoffice_sales_invoice(uuid,bigint,uuid)')) post_definition,
    pg_get_functiondef(to_regprocedure(
      'private.post_backoffice_sales_invoice_financial_event_core(uuid,uuid,bigint,uuid)'))
      finance_definition
), runtime_anchor_contract AS (
  SELECT
    (length(post_definition)-length(replace(post_definition,
      '''taxTotal'',v_invoice.tax_total,','')))/length('''taxTotal'',v_invoice.tax_total,')=1
    AND (length(finance_definition)-length(replace(finance_definition,
      'v_tax numeric(24,4);v_expected_debit numeric(24,4);v_expected_credit numeric(24,4);','')))
        /length('v_tax numeric(24,4);v_expected_debit numeric(24,4);v_expected_credit numeric(24,4);')=1
    AND (length(finance_definition)-length(replace(finance_definition,
      'OR round((v_event.amounts->>''downPaymentDeductionTotal'')::numeric,4)','')))
        /length('OR round((v_event.amounts->>''downPaymentDeductionTotal'')::numeric,4)')=1
    AND (length(finance_definition)-length(replace(finance_definition,
      'v_revenue:=round(v_invoice.charge_total-v_invoice.discount_total,4);','')))
        /length('v_revenue:=round(v_invoice.charge_total-v_invoice.discount_total,4);')=1
    AND (length(finance_definition)-length(replace(finance_definition,
      '''Pendapatan penjualan'');','')))/length('''Pendapatan penjualan'');')=1
    AND (length(finance_definition)-length(replace(finance_definition,
      'v_expected_credit:=round(v_revenue+v_invoice.tax_total,4);','')))
        /length('v_expected_credit:=round(v_revenue+v_invoice.tax_total,4);')=1 valid
  FROM runtime_definitions
), checks AS (
  SELECT 'dependency_ledger'::text check_name,
    CASE WHEN count(*)=(SELECT count(*) FROM required_versions) THEN 'PASS' ELSE 'BLOCKER' END status,
    ((SELECT count(*) FROM required_versions)-count(*))::bigint violation_rows,
    jsonb_build_object('presentVersions',COALESCE(jsonb_agg(version ORDER BY version),'[]')) details
  FROM private.kgs_schema_migrations migration
  WHERE migration.version IN(SELECT version FROM required_versions)
  UNION ALL
  SELECT 'active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'delivery_fee_identity_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('collisionRows',count(*))
  FROM information_schema.columns column_state
  WHERE column_state.table_schema='public' AND column_state.column_name='delivery_fee_amount'
    AND column_state.table_name IN('backoffice_sales_orders','backoffice_sales_invoices')
  UNION ALL
  SELECT 'delivery_fee_routine_collision',CASE WHEN count(*) FILTER(WHERE present)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    count(*) FILTER(WHERE present)::bigint,
    jsonb_build_object('collisions',COALESCE(jsonb_agg(signature ORDER BY signature)
      FILTER(WHERE present),'[]'))
  FROM (SELECT signature,to_regprocedure(signature) IS NOT NULL present FROM (VALUES
      ('public.save_backoffice_sales_order_draft_before_delivery_fee(uuid,bigint,uuid,jsonb)'),
      ('private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(uuid,bigint,uuid,uuid,jsonb)'),
      ('private.backoffice_sales_order_snapshot_before_delivery_fee(uuid,uuid)'),
      ('private.backoffice_sales_invoice_snapshot_before_delivery_fee(uuid,uuid)'),
      ('private.trg_backoffice_sales_order_delivery_fee()'),
      ('private.trg_backoffice_sales_invoice_delivery_fee()')
    ) collision(signature)) routine_collision
  UNION ALL
  SELECT 'delivery_fee_finance_identity_collision',CASE WHEN count(*)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('collisionRows',count(*))
  FROM (
    SELECT rule.id::text identity_value
    FROM public.transaction_categories category
    JOIN public.transaction_account_rules rule ON rule.company_id=category.company_id
      AND rule.transaction_category_id=category.id
    WHERE category.system_key='BACKOFFICE_SALES_INVOICE' AND category.is_active
      AND rule.system_key='BACKOFFICE_SALES_INVOICE'
      AND rule.account_function_key='DELIVERY_FEE_REVENUE'
    UNION ALL
    SELECT event.system_key FROM public.system_events event
    WHERE event.system_key='BACKOFFICE_SALES_INVOICE'
      AND 'DELIVERY_FEE_REVENUE'=ANY(event.conditional_account_functions)
  ) collision
  UNION ALL
  SELECT 'required_active_call_chain',CASE WHEN count(*) FILTER(WHERE present)=7
      THEN 'PASS' ELSE 'BLOCKER' END,
    (7-count(*) FILTER(WHERE present))::bigint,
    jsonb_build_object('present',count(*) FILTER(WHERE present),'expected',7,
      'missing',COALESCE(jsonb_agg(signature ORDER BY signature)
        FILTER(WHERE NOT present),'[]'))
  FROM (SELECT signature,to_regprocedure(signature) IS NOT NULL present FROM (VALUES
      ('public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)'),
      ('public.post_backoffice_sales_invoice(uuid,bigint,uuid)'),
      ('private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)'),
      ('private.backoffice_sales_order_snapshot(uuid,uuid)'),
      ('private.backoffice_sales_invoice_snapshot(uuid,uuid)'),
      ('private.rebuild_backoffice_sales_invoice_schedules(uuid,uuid,uuid)'),
      ('private.post_backoffice_sales_invoice_financial_event_core(uuid,uuid,bigint,uuid)')
    ) required(signature)) required_chain
  UNION ALL
  SELECT 'invoice_runtime_definition_anchor_contract',
    CASE WHEN valid THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN valid THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('requiredUniqueAnchors',6,'valid',valid)
  FROM runtime_anchor_contract
  UNION ALL
  SELECT 'canonical_delivery_fee_account_source',
    CASE WHEN count(*)>0 AND bool_and(COALESCE(source.account_count,0)=1)
      THEN 'PASS' ELSE 'BLOCKER' END,
    count(*) FILTER(WHERE COALESCE(source.account_count,0)<>1)::bigint,
    jsonb_build_object('categoryCompanies',count(*),'invalidCompanies',
      count(*) FILTER(WHERE COALESCE(source.account_count,0)<>1))
  FROM public.transaction_categories category
  LEFT JOIN resolved_sources source ON source.company_id=category.company_id
  WHERE category.system_key='BACKOFFICE_SALES_INVOICE' AND category.is_active
  UNION ALL
  SELECT 'regular_posting_rule_v2',
    CASE WHEN count(*)>0 AND bool_and(mapped.rule_set_version=2 AND mapped.line_count=5)
      THEN 'PASS' ELSE 'BLOCKER' END,
    count(*) FILTER(WHERE mapped.rule_set_version<>2 OR mapped.line_count<>5)::bigint,
    jsonb_build_object('approvedSets',count(*),'invalidSets',
      count(*) FILTER(WHERE mapped.rule_set_version<>2 OR mapped.line_count<>5))
  FROM (SELECT rule_set.id,rule_set.rule_set_version,count(line.id) line_count
    FROM public.posting_rule_sets rule_set
    JOIN public.posting_rule_lines line ON line.company_id=rule_set.company_id
      AND line.rule_set_id=rule_set.id
    WHERE rule_set.system_key='BACKOFFICE_SALES_INVOICE' AND rule_set.status='APPROVED'
    GROUP BY rule_set.id,rule_set.rule_set_version) mapped
  UNION ALL
  SELECT 'regular_posting_rule_category_cardinality',
    CASE WHEN count(*)>0 AND bool_and(mapping_count=1) THEN 'PASS' ELSE 'BLOCKER' END,
    count(*) FILTER(WHERE mapping_count<>1)::bigint,
    jsonb_build_object('categoryCompanies',count(*),'invalidCompanies',
      count(*) FILTER(WHERE mapping_count<>1))
  FROM (SELECT category.company_id,category.id,count(rule_set.id) mapping_count
    FROM public.transaction_categories category
    LEFT JOIN public.posting_rule_sets rule_set
      ON rule_set.company_id=category.company_id
      AND rule_set.transaction_category_id=category.id
      AND rule_set.system_key=category.system_key AND rule_set.status='APPROVED'
    WHERE category.system_key='BACKOFFICE_SALES_INVOICE' AND category.is_active
    GROUP BY category.company_id,category.id) category_rules
  UNION ALL
  SELECT 'runtime_inventory','INFO',0::bigint,jsonb_build_object(
    'orders',(SELECT count(*) FROM public.backoffice_sales_orders),
    'draftInvoices',(SELECT count(*) FROM public.backoffice_sales_invoices WHERE status='DRAFT'),
    'postedInvoices',(SELECT count(*) FROM public.backoffice_sales_invoices WHERE status='POSTED'))
  UNION ALL
  SELECT 'preflight_environment_identity','INFO',0::bigint,jsonb_build_object(
    'database',current_database(),'databaseUser',current_user,
    'serverAddress',inet_server_addr(),'serverPort',inet_server_port())
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
