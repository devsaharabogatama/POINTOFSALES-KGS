-- G6 phase 7B Finance UAT seed preflight.
--
-- SAFETY:
-- - SELECT-only; no business row, context, queue, stock, or journal mutation.
-- - The companion operation intentionally targets exactly one ACTIVE Company.
-- - Run the whole file before the persistent UAT seed operation.

WITH required_versions(version) AS (
    VALUES
        ('20260728120000'), -- Opening Stock
        ('20260728210000'), -- Stock Adjustment
        ('20260810210000'), -- controlled Finance queue
        ('20260811100000')  -- human-readable Finance identifiers
), required_routines(signature) AS (
    VALUES
        ('public.save_product_with_uoms(uuid,bigint,text,text,uuid,uuid,uuid,numeric,boolean,text,boolean,jsonb)'),
        ('public.save_opening_stock_document(uuid,bigint,uuid,date,text,jsonb)'),
        ('public.post_opening_stock(uuid,bigint,uuid)'),
        ('public.save_stock_adjustment_reason(uuid,bigint,text,text,text,boolean)'),
        ('public.save_stock_adjustment_document(uuid,bigint,uuid,date,text,jsonb)'),
        ('public.post_stock_adjustment(uuid,bigint,uuid)'),
        ('public.preview_financial_event_posting_queue(integer)'),
        ('public.approve_financial_event_posting_queue(uuid,bigint)'),
        ('public.process_financial_event_posting_queue(uuid,bigint)')
), target_company AS (
    SELECT company.id AS company_id
    FROM public.companies company
    WHERE company.status='ACTIVE'
), master_readiness AS (
    SELECT
        company.company_id,
        EXISTS (
            SELECT 1 FROM public.product_categories category
            WHERE category.company_id=company.company_id
              AND category.is_active
        ) AS has_category,
        EXISTS (
            SELECT 1 FROM public.uoms uom
            WHERE uom.company_id=company.company_id AND uom.is_active
        ) AS has_uom,
        EXISTS (
            SELECT 1 FROM public.warehouses warehouse
            WHERE warehouse.company_id=company.company_id
              AND warehouse.is_active
        ) AS has_warehouse
    FROM target_company company
), checks AS (
    SELECT
        'required_migration_chain'::TEXT AS check_name,
        CASE WHEN count(*) FILTER(WHERE ledger.version IS NULL)=0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(required.version ORDER BY required.version)
                    FILTER(WHERE ledger.version IS NULL),
                '[]'::JSONB
            )
        ) AS details
    FROM required_versions required
    LEFT JOIN private.kgs_schema_migrations ledger
      ON ledger.version=required.version

    UNION ALL

    SELECT
        'single_active_company_seed_scope',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('active_company_count',count(*))
    FROM target_company

    UNION ALL

    SELECT
        'linked_super_admin_seed_actor',
        CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('actor_count',count(*))
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.role::TEXT='super_admin'

    UNION ALL

    SELECT
        'required_guarded_routines',
        CASE WHEN count(*) FILTER(
            WHERE to_regprocedure(required.signature) IS NULL
        )=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(required.signature ORDER BY required.signature)
                    FILTER(WHERE to_regprocedure(required.signature) IS NULL),
                '[]'::JSONB
            )
        )
    FROM required_routines required

    UNION ALL

    SELECT
        'operational_master_readiness',
        CASE WHEN count(*)=1
                   AND bool_and(has_category AND has_uom AND has_warehouse)
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'company_count',count(*),
            'without_category',count(*) FILTER(WHERE NOT has_category),
            'without_uom',count(*) FILTER(WHERE NOT has_uom),
            'without_warehouse',count(*) FILTER(WHERE NOT has_warehouse)
        )
    FROM master_readiness

    UNION ALL

    SELECT
        'finance_account_function_readiness',
        CASE WHEN count(DISTINCT account.system_function_key)=3
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'expected_functions',3,
            'resolved_functions',count(DISTINCT account.system_function_key)
        )
    FROM target_company company
    LEFT JOIN public.chart_of_accounts account
      ON account.company_id=company.company_id
     AND account.is_active
     AND account.is_postable
     AND account.system_function_key IN (
         'INVENTORY_ASSET','OPENING_BALANCE_CLEARING','STOCK_GAIN_INCOME'
     )

    UNION ALL

    SELECT
        'finance_transaction_category_readiness',
        CASE WHEN count(DISTINCT category.system_key)=2
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'expected_system_keys',2,
            'resolved_system_keys',count(DISTINCT category.system_key)
        )
    FROM target_company company
    LEFT JOIN public.transaction_categories category
     ON category.company_id=company.company_id
     AND category.is_active
     AND category.is_system_default
     AND category.system_key IN ('STOCK_OPENING','STOCK_GAIN')

    UNION ALL

    SELECT
        'current_accounting_period_readiness',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('current_postable_periods',count(*))
    FROM public.accounting_periods period
    JOIN target_company company ON company.company_id=period.company_id
    WHERE CURRENT_DATE BETWEEN period.start_date AND period.end_date
      AND period.status IN ('OPEN','REOPENED')

    UNION ALL

    SELECT
        'stock_opening_posting_rule_readiness',
        CASE WHEN count(*)=1
                   AND min(scope.line_count)=2
                   AND max(scope.line_count)=2
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'approved_rule_sets',count(*),
            'posting_rule_lines',COALESCE(sum(scope.line_count),0)
        )
    FROM (
        SELECT rule_set.company_id,rule_set.id,count(line.id) AS line_count
        FROM public.posting_rule_sets rule_set
        JOIN target_company company
          ON company.company_id=rule_set.company_id
        JOIN public.transaction_categories category
          ON category.company_id=rule_set.company_id
         AND category.id=rule_set.transaction_category_id
         AND category.system_key='STOCK_OPENING'
        LEFT JOIN public.posting_rule_lines line
          ON line.company_id=rule_set.company_id
         AND line.rule_set_id=rule_set.id
        WHERE rule_set.system_key='STOCK_OPENING'
          AND rule_set.status='APPROVED'
          AND rule_set.effective_from<=clock_timestamp()
          AND (
              rule_set.effective_to IS NULL
              OR rule_set.effective_to>clock_timestamp()
          )
        GROUP BY rule_set.company_id,rule_set.id
    ) scope

    UNION ALL

    SELECT
        'active_finance_queue',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('run_count',count(*))
    FROM public.finance_posting_queue_runs run
    JOIN target_company company ON company.company_id=run.company_id
    WHERE run.status IN ('PREVIEWED','APPROVED','PROCESSING')

    UNION ALL

    SELECT
        'existing_supported_hold_scope',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('event_count',count(*))
    FROM public.financial_events event
    JOIN target_company company ON company.company_id=event.company_id
    WHERE event.status::TEXT='HOLD'
      AND event.system_event_key='STOCK_OPENING'
      AND event.event_type::TEXT='STOCK_OPENING'
      AND event.source_table='opening_stock_documents'
      AND NOT EXISTS (
          SELECT 1 FROM public.finance_journals journal
          WHERE journal.company_id=event.company_id
            AND journal.financial_event_id=event.id
      )

    UNION ALL

    SELECT
        'uat_seed_identity_collision',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('product_count',count(*))
    FROM public.products product
    JOIN target_company company ON company.company_id=product.company_id
    WHERE upper(btrim(product.sku))='UAT-FIN-001'
       OR lower(regexp_replace(btrim(product.name),'\s+',' ','g'))=
          'uat finance product'
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
    check_name;
