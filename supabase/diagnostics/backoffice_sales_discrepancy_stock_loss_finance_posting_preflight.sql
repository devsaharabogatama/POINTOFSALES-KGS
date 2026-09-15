-- SELECT-only preflight for Step 5/6.2. Run the entire file.
WITH facts AS (
  SELECT
    EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912134000') dependency_ok,
    EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912135000') migration_applied,
    to_regprocedure('private.post_backoffice_discrepancy_stock_loss_financial_event_core(uuid,uuid,bigint,uuid)') IS NOT NULL core_exists,
    to_regprocedure('private.post_financial_event_core_pre_backoffice_discrepancy_stock_loss(uuid,uuid,bigint,uuid)') IS NOT NULL prior_exists,
    to_regprocedure('private.f4b_financial_event_supported_pre_backoffice_discrepancy_stock_loss(public.financial_events)') IS NOT NULL support_prior_exists,
    to_regprocedure('private.provision_backoffice_discrepancy_stock_loss_finance(uuid,uuid)') IS NOT NULL provision_exists,
    to_regprocedure('private.trg_provision_backoffice_discrepancy_stock_loss_finance()') IS NOT NULL provision_trigger_exists,
    (SELECT count(*) FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) active_finance,
    (SELECT count(*) FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) offline_rows
), mapping_state AS (
  SELECT company.id company_id,category.category_count,category.category_id,
    (SELECT count(*) FROM public.transaction_account_rules rule
      WHERE rule.company_id=company.id AND rule.transaction_category_id=category.category_id
        AND rule.system_key='STOCK_LOSS' AND rule.account_function_key='STOCK_LOSS_EXPENSE'
        AND rule.status='ACTIVE' AND rule.effective_from<=statement_timestamp()
        AND (rule.effective_to IS NULL OR rule.effective_to>statement_timestamp())) loss_exact,
    (SELECT count(*) FROM public.transaction_account_rules rule
      JOIN public.chart_of_accounts account ON account.company_id=rule.company_id
        AND account.id=rule.account_id AND account.is_active AND account.is_postable
      JOIN public.account_functions function_state
        ON function_state.function_key='STOCK_LOSS_EXPENSE' AND function_state.is_active
        AND account.account_type=ANY(function_state.compatible_account_types)
      WHERE rule.company_id=company.id AND rule.transaction_category_id=category.category_id
        AND rule.system_key='STOCK_LOSS' AND rule.account_function_key='STOCK_LOSS_EXPENSE'
        AND rule.status='ACTIVE' AND rule.effective_from<=statement_timestamp()
        AND (rule.effective_to IS NULL OR rule.effective_to>statement_timestamp())) loss_exact_valid,
    (SELECT count(*) FROM public.company_account_function_fallbacks fallback
      WHERE fallback.company_id=company.id AND fallback.account_function_key='STOCK_LOSS_EXPENSE'
        AND fallback.status='ACTIVE' AND fallback.effective_from<=statement_timestamp()
        AND (fallback.effective_to IS NULL OR fallback.effective_to>statement_timestamp())) loss_fallback,
    (SELECT count(*) FROM public.company_account_function_fallbacks fallback
      JOIN public.chart_of_accounts account ON account.company_id=fallback.company_id
        AND account.id=fallback.account_id AND account.is_active AND account.is_postable
      JOIN public.account_functions function_state
        ON function_state.function_key='STOCK_LOSS_EXPENSE' AND function_state.is_active
        AND account.account_type=ANY(function_state.compatible_account_types)
      WHERE fallback.company_id=company.id AND fallback.account_function_key='STOCK_LOSS_EXPENSE'
        AND fallback.status='ACTIVE' AND fallback.effective_from<=statement_timestamp()
        AND (fallback.effective_to IS NULL OR fallback.effective_to>statement_timestamp())) loss_fallback_valid,
    (SELECT count(*) FROM public.chart_of_accounts account
      JOIN public.account_functions function_state
        ON function_state.function_key='STOCK_LOSS_EXPENSE' AND function_state.is_active
      WHERE account.company_id=company.id AND account.system_function_key='STOCK_LOSS_EXPENSE'
        AND account.is_system_account AND account.is_active AND account.is_postable
        AND account.account_type=ANY(function_state.compatible_account_types)) loss_system,
    (SELECT count(*) FROM public.transaction_account_rules rule
      WHERE rule.company_id=company.id AND rule.transaction_category_id=category.category_id
        AND rule.system_key='STOCK_LOSS' AND rule.account_function_key='INVENTORY_ASSET'
        AND rule.status='ACTIVE' AND rule.effective_from<=statement_timestamp()
        AND (rule.effective_to IS NULL OR rule.effective_to>statement_timestamp())) inventory_exact,
    (SELECT count(*) FROM public.transaction_account_rules rule
      JOIN public.chart_of_accounts account ON account.company_id=rule.company_id
        AND account.id=rule.account_id AND account.is_active AND account.is_postable
      JOIN public.account_functions function_state
        ON function_state.function_key='INVENTORY_ASSET' AND function_state.is_active
        AND account.account_type=ANY(function_state.compatible_account_types)
      WHERE rule.company_id=company.id AND rule.transaction_category_id=category.category_id
        AND rule.system_key='STOCK_LOSS' AND rule.account_function_key='INVENTORY_ASSET'
        AND rule.status='ACTIVE' AND rule.effective_from<=statement_timestamp()
        AND (rule.effective_to IS NULL OR rule.effective_to>statement_timestamp())) inventory_exact_valid,
    (SELECT count(*) FROM public.company_account_function_fallbacks fallback
      WHERE fallback.company_id=company.id AND fallback.account_function_key='INVENTORY_ASSET'
        AND fallback.status='ACTIVE' AND fallback.effective_from<=statement_timestamp()
        AND (fallback.effective_to IS NULL OR fallback.effective_to>statement_timestamp())) inventory_fallback,
    (SELECT count(*) FROM public.company_account_function_fallbacks fallback
      JOIN public.chart_of_accounts account ON account.company_id=fallback.company_id
        AND account.id=fallback.account_id AND account.is_active AND account.is_postable
      JOIN public.account_functions function_state
        ON function_state.function_key='INVENTORY_ASSET' AND function_state.is_active
        AND account.account_type=ANY(function_state.compatible_account_types)
      WHERE fallback.company_id=company.id AND fallback.account_function_key='INVENTORY_ASSET'
        AND fallback.status='ACTIVE' AND fallback.effective_from<=statement_timestamp()
        AND (fallback.effective_to IS NULL OR fallback.effective_to>statement_timestamp())) inventory_fallback_valid,
    (SELECT count(*) FROM public.chart_of_accounts account
      JOIN public.account_functions function_state
        ON function_state.function_key='INVENTORY_ASSET' AND function_state.is_active
      WHERE account.company_id=company.id AND account.system_function_key='INVENTORY_ASSET'
        AND account.is_system_account AND account.is_active AND account.is_postable
        AND account.account_type=ANY(function_state.compatible_account_types)) inventory_system,
    rule_state.approved_sets,rule_state.total_sets,rule_state.approved_set_id,
    (SELECT count(*) FROM public.posting_rule_lines line
      WHERE line.company_id=company.id AND line.rule_set_id=rule_state.approved_set_id) approved_lines,
    EXISTS(SELECT 1 FROM public.posting_rule_lines line
      WHERE line.company_id=company.id AND line.rule_set_id=rule_state.approved_set_id
        AND line.account_function_key='STOCK_LOSS_EXPENSE' AND line.entry_side='DEBIT'
        AND line.amount_expression_key='BACKOFFICE_DISCREPANCY_FIFO_COST'
        AND line.is_required) loss_debit,
    EXISTS(SELECT 1 FROM public.posting_rule_lines line
      WHERE line.company_id=company.id AND line.rule_set_id=rule_state.approved_set_id
        AND line.account_function_key='INVENTORY_ASSET' AND line.entry_side='CREDIT'
        AND line.amount_expression_key='BACKOFFICE_DISCREPANCY_FIFO_COST'
        AND line.is_required) inventory_credit
  FROM public.companies company
  CROSS JOIN LATERAL(SELECT count(*) category_count,
    (array_agg(category.id ORDER BY category.id))[1] category_id
    FROM public.transaction_categories category WHERE category.company_id=company.id
      AND category.system_key='STOCK_LOSS' AND category.is_active) category
  CROSS JOIN LATERAL(SELECT count(*) FILTER(WHERE rule_set.status='APPROVED'
      AND rule_set.effective_from<=statement_timestamp()
      AND (rule_set.effective_to IS NULL OR rule_set.effective_to>statement_timestamp())) approved_sets,
    count(*) total_sets,(array_agg(rule_set.id ORDER BY rule_set.rule_set_version DESC,rule_set.id)
      FILTER(WHERE rule_set.status='APPROVED' AND rule_set.effective_from<=statement_timestamp()
        AND (rule_set.effective_to IS NULL OR rule_set.effective_to>statement_timestamp())))[1]
      approved_set_id
    FROM public.posting_rule_sets rule_set WHERE rule_set.company_id=company.id
      AND rule_set.transaction_category_id=category.category_id
      AND rule_set.system_key='STOCK_LOSS') rule_state
  WHERE company.status='ACTIVE'
), checks AS (
  SELECT 's5_2_dependency_ledger' check_name,
    CASE WHEN dependency_ok THEN 'PASS' ELSE 'BLOCKER' END status,
    CASE WHEN dependency_ok THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('requiredVersion','20260912134000','present',dependency_ok) details FROM facts
  UNION ALL SELECT 's5_2_wrapper_collision',
    CASE WHEN (migration_applied AND core_exists AND prior_exists AND support_prior_exists
        AND provision_exists AND provision_trigger_exists)
      OR (NOT migration_applied AND NOT core_exists AND NOT prior_exists AND NOT support_prior_exists
        AND NOT provision_exists AND NOT provision_trigger_exists)
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN (migration_applied AND core_exists AND prior_exists AND support_prior_exists
        AND provision_exists AND provision_trigger_exists)
      OR (NOT migration_applied AND NOT core_exists AND NOT prior_exists AND NOT support_prior_exists
        AND NOT provision_exists AND NOT provision_trigger_exists)
      THEN 0 ELSE 1 END,
    jsonb_build_object('migrationApplied',migration_applied,'core',core_exists,
      'postPrior',prior_exists,'supportPrior',support_prior_exists,
      'provision',provision_exists,'provisionTrigger',provision_trigger_exists) FROM facts
  UNION ALL SELECT 's5_2_active_finance_queue',CASE WHEN active_finance=0 THEN 'PASS' ELSE 'BLOCKER' END,
    active_finance,jsonb_build_object('runRows',active_finance) FROM facts
  UNION ALL SELECT 's5_2_nonterminal_offline',CASE WHEN offline_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
    offline_rows,jsonb_build_object('submissionRows',offline_rows) FROM facts
  UNION ALL SELECT 's5_2_event_source_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.financial_events event
  LEFT JOIN public.backoffice_sales_discrepancy_stock_effects effect
    ON effect.company_id=event.company_id AND effect.id=event.source_id
    AND effect.financial_event_id=event.id
  LEFT JOIN public.backoffice_sales_delivery_discrepancy_lines line
    ON line.company_id=effect.company_id AND line.id=effect.discrepancy_line_id
  WHERE event.system_event_key='STOCK_LOSS'
    AND event.source_table='backoffice_sales_discrepancy_stock_effects'
    AND (event.event_type::text<>'STOCK_LOSS' OR effect.id IS NULL
      OR effect.effect_type<>'EXPECTED_WRITE_OFF' OR line.id IS NULL
      OR line.physical_state NOT IN('LOST','DAMAGED')
      OR jsonb_typeof(event.amounts) IS DISTINCT FROM 'object'
      OR jsonb_typeof(event.amounts->'stockLossDebit') IS DISTINCT FROM 'number'
      OR jsonb_typeof(event.amounts->'inventoryCredit') IS DISTINCT FROM 'number'
      OR event.transaction_category_id IS NULL)
  UNION ALL SELECT 's5_2_cost_lineage_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.financial_events event
  JOIN public.backoffice_sales_discrepancy_stock_effects effect
    ON effect.company_id=event.company_id AND effect.id=event.source_id
    AND effect.financial_event_id=event.id
  WHERE event.system_event_key='STOCK_LOSS'
    AND event.source_table='backoffice_sales_discrepancy_stock_effects'
    AND (round(CASE WHEN jsonb_typeof(event.amounts->'stockLossDebit')='number'
          THEN (event.amounts->>'stockLossDebit')::numeric END,4) IS DISTINCT FROM round(effect.total_cost,4)
      OR round(CASE WHEN jsonb_typeof(event.amounts->'inventoryCredit')='number'
          THEN (event.amounts->>'inventoryCredit')::numeric END,4) IS DISTINCT FROM round(effect.total_cost,4)
      OR round(effect.quantity_base,6)<>(SELECT round(COALESCE(sum(allocation.quantity_base),0),6)
        FROM public.backoffice_sales_discrepancy_fifo_allocations allocation
        WHERE allocation.company_id=effect.company_id AND allocation.stock_effect_id=effect.id)
      OR round(effect.total_cost,4)<>(SELECT round(COALESCE(sum(allocation.total_cost),0),4)
        FROM public.backoffice_sales_discrepancy_fifo_allocations allocation
        WHERE allocation.company_id=effect.company_id AND allocation.stock_effect_id=effect.id)
      OR NOT EXISTS(SELECT 1 FROM public.stock_movements movement
        WHERE movement.company_id=effect.company_id AND movement.id=effect.source_stock_movement_id
          AND movement.reference_table='backoffice_sales_discrepancy_stock_effects'
          AND movement.reference_id=effect.id AND movement.product_id=effect.product_id
          AND movement.warehouse_id=effect.source_warehouse_id
          AND movement.movement_status='POSTED'
          AND round(movement.qty_change,6)=-round(effect.quantity_base,6)))
  UNION ALL SELECT 's5_2_mapping_source_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidCompanies',count(*),'companies',COALESCE(jsonb_agg(
      jsonb_build_object('companyId',company_id,'categoryCount',category_count,
        'lossExact',loss_exact,'lossFallback',loss_fallback,'lossSystem',loss_system,
        'lossExactValid',loss_exact_valid,'lossFallbackValid',loss_fallback_valid,
        'inventoryExact',inventory_exact,'inventoryFallback',inventory_fallback,
        'inventoryExactValid',inventory_exact_valid,
        'inventoryFallbackValid',inventory_fallback_valid,
        'inventorySystem',inventory_system)),'[]'::jsonb))
  FROM mapping_state WHERE category_count<>1 OR loss_exact>1 OR loss_exact_valid<>loss_exact
    OR (loss_exact=0 AND (loss_fallback>1 OR loss_fallback_valid<>loss_fallback
      OR (loss_fallback=0 AND loss_system<>1)))
    OR inventory_exact>1 OR inventory_exact_valid<>inventory_exact
    OR (inventory_exact=0 AND (inventory_fallback>1
      OR inventory_fallback_valid<>inventory_fallback
      OR (inventory_fallback=0 AND inventory_system<>1)))
  UNION ALL SELECT 's5_2_posting_rule_provision_contract',
    CASE WHEN count(*) FILTER(WHERE NOT ((approved_sets=0 AND total_sets=0)
        OR (approved_sets=1 AND approved_lines=2 AND loss_debit AND inventory_credit)))=0
      THEN CASE WHEN count(*) FILTER(WHERE approved_sets=0 AND total_sets=0)>0
        THEN 'SETUP' ELSE 'PASS' END ELSE 'BLOCKER' END,
    count(*) FILTER(WHERE NOT ((approved_sets=0 AND total_sets=0)
      OR (approved_sets=1 AND approved_lines=2 AND loss_debit AND inventory_credit)))::bigint,
    jsonb_build_object('companies',jsonb_agg(jsonb_build_object('companyId',company_id,
      'approvedSets',approved_sets,'totalSets',total_sets,'approvedLines',approved_lines,
      'lossDebit',loss_debit,'inventoryCredit',inventory_credit)),
      'setupCompanies',count(*) FILTER(WHERE approved_sets=0 AND total_sets=0),
      'rule','Absent rule is provisioned by migration; partial, ambiguous, or malformed rule blocks')
  FROM mapping_state
  UNION ALL SELECT 's5_2_runtime_inventory','INFO',0,
    jsonb_build_object('holdEvents',(SELECT count(*) FROM public.financial_events
      WHERE system_event_key='STOCK_LOSS' AND source_table='backoffice_sales_discrepancy_stock_effects'
        AND status='HOLD'),
      'postedEvents',(SELECT count(*) FROM public.financial_events
      WHERE system_event_key='STOCK_LOSS' AND source_table='backoffice_sales_discrepancy_stock_effects'
        AND status='POSTED'),
      'openPeriods',(SELECT count(*) FROM public.accounting_periods
      WHERE status IN('OPEN','REOPENED'))) FROM facts
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY
  CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
