-- SELECT-only preflight for Step 5/6.1. Run the entire file.
WITH facts AS (
  SELECT
    EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912133000') dependency_ok,
    EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912134000') migration_applied,
    to_regprocedure('private.post_backoffice_accepted_overage_financial_event_core(uuid,uuid,bigint,uuid)') IS NOT NULL core_exists,
    to_regprocedure('private.post_financial_event_core_pre_backoffice_accepted_overage(uuid,uuid,bigint,uuid)') IS NOT NULL prior_exists,
    to_regprocedure('private.f4b_financial_event_supported_pre_backoffice_accepted_overage(public.financial_events)') IS NOT NULL support_prior_exists,
    (SELECT count(*) FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) active_finance,
    (SELECT count(*) FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) offline_rows
), checks AS (
  SELECT 's5_1_dependency_ledger' check_name,
    CASE WHEN dependency_ok THEN 'PASS' ELSE 'BLOCKER' END status,
    CASE WHEN dependency_ok THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('requiredVersion','20260912133000','present',dependency_ok) details FROM facts
  UNION ALL SELECT 's5_1_wrapper_collision',
    CASE WHEN (migration_applied AND core_exists AND prior_exists AND support_prior_exists)
      OR (NOT migration_applied AND NOT core_exists AND NOT prior_exists AND NOT support_prior_exists)
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN (migration_applied AND core_exists AND prior_exists AND support_prior_exists)
      OR (NOT migration_applied AND NOT core_exists AND NOT prior_exists AND NOT support_prior_exists)
      THEN 0 ELSE 1 END,
    jsonb_build_object('migrationApplied',migration_applied,'core',core_exists,
      'postPrior',prior_exists,'supportPrior',support_prior_exists) FROM facts
  UNION ALL SELECT 's5_1_active_finance_queue',CASE WHEN active_finance=0 THEN 'PASS' ELSE 'BLOCKER' END,
    active_finance,jsonb_build_object('runRows',active_finance) FROM facts
  UNION ALL SELECT 's5_1_nonterminal_offline',CASE WHEN offline_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
    offline_rows,jsonb_build_object('submissionRows',offline_rows) FROM facts
  UNION ALL SELECT 's5_1_event_source_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.financial_events event
  LEFT JOIN public.backoffice_sales_discrepancy_stock_effects effect
    ON effect.company_id=event.company_id AND effect.id=event.source_id
    AND effect.financial_event_id=event.id
  WHERE event.system_event_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
    AND (event.source_table<>'backoffice_sales_discrepancy_stock_effects'
      OR event.event_type::text<>'SALE_POSTED' OR effect.id IS NULL
      OR effect.effect_type<>'OVERAGE_ACCEPTED_SALE'
      OR jsonb_typeof(event.amounts) IS DISTINCT FROM 'object'
      OR jsonb_typeof(event.amounts->'fifoCostTotal') IS DISTINCT FROM 'number'
      OR jsonb_typeof(event.amounts->'acceptedDate') IS DISTINCT FROM 'string'
      OR event.transaction_category_id IS NULL OR event.transaction_rule_version IS NULL
      OR NOT EXISTS(SELECT 1 FROM public.posting_rule_sets rule_set
        WHERE rule_set.company_id=event.company_id
          AND rule_set.transaction_category_id=event.transaction_category_id
          AND rule_set.system_key=event.system_event_key
          AND rule_set.rule_set_version=event.transaction_rule_version
          AND rule_set.status='APPROVED' AND rule_set.effective_from<=event.event_date
          AND (rule_set.effective_to IS NULL OR rule_set.effective_to>event.event_date)))
  UNION ALL SELECT 's5_1_cost_lineage_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.financial_events event
  JOIN public.backoffice_sales_discrepancy_stock_effects effect
    ON effect.company_id=event.company_id AND effect.id=event.source_id
    AND effect.financial_event_id=event.id
  WHERE event.system_event_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
    AND jsonb_typeof(event.amounts->'fifoCostTotal')='number'
    AND (round((event.amounts->>'fifoCostTotal')::numeric,4)<>round(effect.total_cost,4)
      OR round(effect.quantity_base,6)<>(SELECT round(COALESCE(sum(allocation.quantity_base),0),6)
        FROM public.backoffice_sales_discrepancy_fifo_allocations allocation
        WHERE allocation.company_id=effect.company_id AND allocation.stock_effect_id=effect.id)
      OR round(effect.total_cost,4)<>(SELECT round(COALESCE(sum(allocation.total_cost),0),4)
        FROM public.backoffice_sales_discrepancy_fifo_allocations allocation
        WHERE allocation.company_id=effect.company_id AND allocation.stock_effect_id=effect.id)
      OR NOT EXISTS(SELECT 1 FROM public.stock_movements movement
        WHERE movement.company_id=effect.company_id
          AND movement.id=effect.source_stock_movement_id
          AND movement.reference_table='backoffice_sales_discrepancy_stock_effects'
          AND movement.reference_id=effect.id AND movement.product_id=effect.product_id
          AND movement.warehouse_id=effect.source_warehouse_id
          AND movement.movement_status='POSTED'
          AND round(movement.qty_change,6)=-round(effect.quantity_base,6)))
  UNION ALL SELECT 's5_1_mapping_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidCompanies',count(*))
  FROM (
    SELECT company.id FROM public.companies company WHERE company.status='ACTIVE'
      AND ((SELECT count(*) FROM public.transaction_categories category
        WHERE category.company_id=company.id
          AND category.system_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS' AND category.is_active)<>1
        OR (SELECT count(DISTINCT rule.account_function_key)
          FROM public.transaction_categories category
          JOIN public.transaction_account_rules rule
            ON rule.company_id=category.company_id
           AND rule.transaction_category_id=category.id AND rule.status='ACTIVE'
          WHERE category.company_id=company.id
            AND category.system_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
            AND rule.account_function_key IN('COGS','INVENTORY_ASSET'))<>2
        OR (SELECT count(*) FROM public.transaction_categories category
          JOIN public.posting_rule_sets rule_set
            ON rule_set.company_id=category.company_id
           AND rule_set.transaction_category_id=category.id
          WHERE category.company_id=company.id
            AND category.system_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
            AND rule_set.system_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
            AND rule_set.status='APPROVED' AND rule_set.effective_from<=statement_timestamp()
            AND (rule_set.effective_to IS NULL OR rule_set.effective_to>statement_timestamp()))<>1)
  ) invalid
  UNION ALL SELECT 's5_1_runtime_inventory','INFO',0,
    jsonb_build_object('holdEvents',(SELECT count(*) FROM public.financial_events
      WHERE system_event_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS' AND status='HOLD'),
      'postedEvents',(SELECT count(*) FROM public.financial_events
      WHERE system_event_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS' AND status='POSTED'),
      'openPeriods',(SELECT count(*) FROM public.accounting_periods
      WHERE status IN('OPEN','REOPENED'))) FROM facts
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY
  CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
