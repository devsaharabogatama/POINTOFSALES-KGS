-- SELECT-only postflight for Step 5/6.2. Run the entire file.
WITH post_routine AS (
  SELECT p.oid,p.prosecdef,p.proconfig,pg_get_functiondef(p.oid) definition
  FROM pg_proc p WHERE p.oid=to_regprocedure(
    'private.post_backoffice_discrepancy_stock_loss_financial_event_core(uuid,uuid,bigint,uuid)')
), dispatcher AS (
  SELECT pg_get_functiondef(to_regprocedure(
    'private.post_financial_event_core(uuid,uuid,bigint,uuid)')) definition
), supported AS (
  SELECT pg_get_functiondef(to_regprocedure(
    'private.f4b_financial_event_supported(public.financial_events)')) definition
), mapping_state AS (
  SELECT company.id company_id,
    count(DISTINCT category.id) category_count,
    count(DISTINCT rule.id) FILTER(WHERE rule.account_function_key='STOCK_LOSS_EXPENSE') loss_rules,
    count(DISTINCT rule.id) FILTER(WHERE rule.account_function_key='INVENTORY_ASSET') inventory_rules,
    count(DISTINCT rule.id) FILTER(WHERE rule.account_function_key='STOCK_LOSS_EXPENSE'
      AND account.is_active AND account.is_postable
      AND account.account_type=ANY(function_state.compatible_account_types)) loss_valid_rules,
    count(DISTINCT rule.id) FILTER(WHERE rule.account_function_key='INVENTORY_ASSET'
      AND account.is_active AND account.is_postable
      AND account.account_type=ANY(function_state.compatible_account_types)) inventory_valid_rules,
    count(DISTINCT rule_set.id) approved_sets,
    count(DISTINCT line.id) posting_lines,
    count(DISTINCT line.id) FILTER(WHERE line.account_function_key='STOCK_LOSS_EXPENSE'
      AND line.entry_side='DEBIT'
      AND line.amount_expression_key='BACKOFFICE_DISCREPANCY_FIFO_COST'
      AND line.is_required) loss_debit,
    count(DISTINCT line.id) FILTER(WHERE line.account_function_key='INVENTORY_ASSET'
      AND line.entry_side='CREDIT'
      AND line.amount_expression_key='BACKOFFICE_DISCREPANCY_FIFO_COST'
      AND line.is_required) inventory_credit
  FROM public.companies company
  LEFT JOIN public.transaction_categories category ON category.company_id=company.id
    AND category.system_key='STOCK_LOSS' AND category.is_active
  LEFT JOIN public.transaction_account_rules rule ON rule.company_id=company.id
    AND rule.transaction_category_id=category.id AND rule.system_key='STOCK_LOSS'
    AND rule.account_function_key IN('STOCK_LOSS_EXPENSE','INVENTORY_ASSET')
    AND rule.status='ACTIVE' AND rule.effective_from<=statement_timestamp()
    AND (rule.effective_to IS NULL OR rule.effective_to>statement_timestamp())
  LEFT JOIN public.chart_of_accounts account ON account.company_id=rule.company_id
    AND account.id=rule.account_id
  LEFT JOIN public.account_functions function_state
    ON function_state.function_key=rule.account_function_key AND function_state.is_active
  LEFT JOIN public.posting_rule_sets rule_set ON rule_set.company_id=company.id
    AND rule_set.transaction_category_id=category.id AND rule_set.system_key='STOCK_LOSS'
    AND rule_set.status='APPROVED' AND rule_set.effective_from<=statement_timestamp()
    AND (rule_set.effective_to IS NULL OR rule_set.effective_to>statement_timestamp())
  LEFT JOIN public.posting_rule_lines line ON line.company_id=company.id
    AND line.rule_set_id=rule_set.id
  WHERE company.status='ACTIVE'
  GROUP BY company.id
), checks AS (
  SELECT 's5_2_migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260912135000'
  UNION ALL SELECT 's5_2_required_routines',
    CASE WHEN count(*)=7 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-7)::bigint,jsonb_build_object('routineRows',count(*),'expected',7)
  FROM (VALUES
    (to_regprocedure('private.provision_backoffice_discrepancy_stock_loss_finance(uuid,uuid)')),
    (to_regprocedure('private.trg_provision_backoffice_discrepancy_stock_loss_finance()')),
    (to_regprocedure('private.post_backoffice_discrepancy_stock_loss_financial_event_core(uuid,uuid,bigint,uuid)')),
    (to_regprocedure('private.post_financial_event_core(uuid,uuid,bigint,uuid)')),
    (to_regprocedure('private.post_financial_event_core_pre_backoffice_discrepancy_stock_loss(uuid,uuid,bigint,uuid)')),
    (to_regprocedure('private.f4b_financial_event_supported(public.financial_events)')),
    (to_regprocedure('private.f4b_financial_event_supported_pre_backoffice_discrepancy_stock_loss(public.financial_events)'))
  ) required(oid) WHERE oid IS NOT NULL
  UNION ALL SELECT 's5_2_private_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('browserExecutableRows',count(*))
  FROM pg_proc proc JOIN pg_namespace ns ON ns.oid=proc.pronamespace
  WHERE ns.nspname='private' AND proc.proname IN(
    'post_backoffice_discrepancy_stock_loss_financial_event_core',
    'provision_backoffice_discrepancy_stock_loss_finance',
    'trg_provision_backoffice_discrepancy_stock_loss_finance',
    'post_financial_event_core_pre_backoffice_discrepancy_stock_loss',
    'f4b_financial_event_supported_pre_backoffice_discrepancy_stock_loss')
    AND (has_function_privilege('anon',proc.oid,'EXECUTE')
      OR has_function_privilege('authenticated',proc.oid,'EXECUTE'))
  UNION ALL SELECT 's5_2_posting_runtime_contract',
    CASE WHEN count(*)=1 AND bool_and(prosecdef
      AND proconfig @> ARRAY['search_path=public, pg_temp']) THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(prosecdef
      AND proconfig @> ARRAY['search_path=public, pg_temp']) THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*),'securityDefiner',coalesce(bool_and(prosecdef),false),
      'config',min(proconfig::text)) FROM post_routine
  UNION ALL SELECT 's5_2_provision_trigger_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-1)::bigint,jsonb_build_object('triggerRows',count(*),'expected',1)
  FROM pg_trigger trigger_state
  WHERE trigger_state.tgrelid='public.companies'::regclass
    AND trigger_state.tgname='zz_provision_backoffice_discrepancy_stock_loss_finance'
    AND NOT trigger_state.tgisinternal
  UNION ALL SELECT 's5_2_mapping_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidCompanies',count(*),'companies',COALESCE(jsonb_agg(
      jsonb_build_object('companyId',company_id,'categoryCount',category_count,
        'lossRules',loss_rules,'inventoryRules',inventory_rules,
        'lossValidRules',loss_valid_rules,'inventoryValidRules',inventory_valid_rules,
        'approvedSets',approved_sets,'postingLines',posting_lines,
        'lossDebit',loss_debit,'inventoryCredit',inventory_credit)),'[]'::jsonb))
  FROM mapping_state WHERE category_count<>1 OR loss_rules<>1 OR inventory_rules<>1
    OR loss_valid_rules<>1 OR inventory_valid_rules<>1
    OR approved_sets<>1 OR posting_lines<>2 OR loss_debit<>1 OR inventory_credit<>1
  UNION ALL SELECT 's5_2_dispatcher_chain',
    CASE WHEN position('''STOCK_LOSS''' in definition)>0
      AND position('post_backoffice_discrepancy_stock_loss_financial_event_core' in definition)>0
      AND position('post_financial_event_core_pre_backoffice_discrepancy_stock_loss' in definition)>0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('''STOCK_LOSS''' in definition)>0
      AND position('post_backoffice_discrepancy_stock_loss_financial_event_core' in definition)>0
      AND position('post_financial_event_core_pre_backoffice_discrepancy_stock_loss' in definition)>0
      THEN 0 ELSE 1 END,jsonb_build_object('dispatcherRows',1) FROM dispatcher
  UNION ALL SELECT 's5_2_queue_support_chain',
    CASE WHEN position('''STOCK_LOSS''' in definition)>0
      AND position('f4b_financial_event_supported_pre_backoffice_discrepancy_stock_loss' in definition)>0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('''STOCK_LOSS''' in definition)>0
      AND position('f4b_financial_event_supported_pre_backoffice_discrepancy_stock_loss' in definition)>0
      THEN 0 ELSE 1 END,jsonb_build_object('supportedRows',1) FROM supported
  UNION ALL SELECT 's5_2_hold_queue_coverage',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('unsupportedHoldEvents',count(*))
  FROM public.financial_events event
  WHERE event.system_event_key='STOCK_LOSS'
    AND event.source_table='backoffice_sales_discrepancy_stock_effects' AND event.status='HOLD'
    AND NOT private.f4b_financial_event_supported(event)
  UNION ALL SELECT 's5_2_posted_journal_coverage',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.financial_events event
  LEFT JOIN public.finance_journals journal ON journal.company_id=event.company_id
    AND journal.financial_event_id=event.id AND journal.status='POSTED'
  WHERE event.system_event_key='STOCK_LOSS'
    AND event.source_table='backoffice_sales_discrepancy_stock_effects'
    AND event.status='POSTED' AND journal.id IS NULL
  UNION ALL SELECT 's5_2_posted_journal_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM (
    SELECT effect.id
    FROM public.backoffice_sales_discrepancy_stock_effects effect
    JOIN public.backoffice_sales_delivery_discrepancy_lines discrepancy_line
      ON discrepancy_line.company_id=effect.company_id
     AND discrepancy_line.id=effect.discrepancy_line_id
    JOIN public.financial_events event ON event.company_id=effect.company_id
      AND event.id=effect.financial_event_id AND event.system_event_key='STOCK_LOSS'
      AND event.source_table='backoffice_sales_discrepancy_stock_effects'
      AND event.status='POSTED'
    JOIN public.finance_journals journal ON journal.company_id=event.company_id
      AND journal.financial_event_id=event.id AND journal.status='POSTED'
    LEFT JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
      AND line.journal_id=journal.id
    WHERE effect.effect_type='EXPECTED_WRITE_OFF'
    GROUP BY effect.id,effect.total_cost,effect.source_warehouse_id,
      discrepancy_line.physical_state,journal.source_type,journal.source_id,
      journal.warehouse_id,journal.total_debit,journal.total_credit
    HAVING journal.source_type<>'backoffice_sales_discrepancy_stock_effects'
      OR journal.source_id<>effect.id OR journal.warehouse_id<>effect.source_warehouse_id
      OR round(journal.total_debit,4)<>round(effect.total_cost,4)
      OR round(journal.total_credit,4)<>round(effect.total_cost,4) OR count(line.id)<>2
      OR count(*) FILTER(WHERE line.description='STOCK_LOSS_EXPENSE - '||discrepancy_line.physical_state
        AND round(line.debit,4)=round(effect.total_cost,4))<>1
      OR count(*) FILTER(WHERE line.description='INVENTORY_ASSET - '||discrepancy_line.physical_state
        AND round(line.credit,4)=round(effect.total_cost,4))<>1
  ) invalid
  UNION ALL SELECT 's5_2_runtime_inventory','INFO',0,
    jsonb_build_object('holdEvents',(SELECT count(*) FROM public.financial_events
      WHERE system_event_key='STOCK_LOSS' AND source_table='backoffice_sales_discrepancy_stock_effects'
        AND status='HOLD'),
      'postedEvents',(SELECT count(*) FROM public.financial_events
      WHERE system_event_key='STOCK_LOSS' AND source_table='backoffice_sales_discrepancy_stock_effects'
        AND status='POSTED'),
      'journals',(SELECT count(*) FROM public.finance_journals
      WHERE system_event_key='STOCK_LOSS'
        AND source_type='backoffice_sales_discrepancy_stock_effects'))
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY
  CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
