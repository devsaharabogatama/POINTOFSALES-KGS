-- POS TEMPO backdated order/delivery postflight.
-- SAFETY: SELECT-only.
WITH definitions AS (
  SELECT
    pg_get_functiondef(
      'public.save_pos_sale_draft_with_pricelist(jsonb)'::regprocedure
    ) AS save_definition,
    pg_get_functiondef(
      'private.post_pos_sale_online_core(uuid,bigint,uuid)'::regprocedure
    ) AS post_definition
), checks AS (
  SELECT 'migration_ledger' AS check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END AS violation_rows,
    jsonb_build_object('ledgerRows',count(*)) AS details
  FROM private.kgs_schema_migrations WHERE version='20260826100000'
  UNION ALL
  SELECT 'required_backdate_columns',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    3-count(*),jsonb_build_object('expected',3,'columnRows',count(*))
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='sales_headers'
    AND column_name IN('transaction_date_source','transaction_date_selected_by',
      'transaction_date_selected_at')
  UNION ALL
  SELECT 'tempo_effective_date_guard',
    CASE WHEN to_regprocedure(
      'private.validate_pos_tempo_effective_dates(uuid,timestamp with time zone,timestamp with time zone,text,timestamp with time zone)'
    ) IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN to_regprocedure(
      'private.validate_pos_tempo_effective_dates(uuid,timestamp with time zone,timestamp with time zone,text,timestamp with time zone)'
    ) IS NOT NULL THEN 0 ELSE 1 END,
    jsonb_build_object('routineExists',to_regprocedure(
      'private.validate_pos_tempo_effective_dates(uuid,timestamp with time zone,timestamp with time zone,text,timestamp with time zone)'
    ) IS NOT NULL)
  UNION ALL
  SELECT 'save_runtime_effective_date_contract',
    CASE WHEN save_definition~'transactionAt'
      AND save_definition~'validate_pos_tempo_effective_dates'
      AND save_definition~'CASHIER_SELECTED' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN save_definition~'transactionAt'
      AND save_definition~'validate_pos_tempo_effective_dates'
      AND save_definition~'CASHIER_SELECTED' THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',1)
  FROM definitions
  UNION ALL
  SELECT 'post_runtime_effective_date_contract',
    CASE WHEN post_definition~'validate_pos_tempo_effective_dates'
      AND post_definition~'v_sale.transaction_date[[:space:]]*,[[:space:]]*1[[:space:]]*,' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN post_definition~'validate_pos_tempo_effective_dates'
      AND post_definition~'v_sale.transaction_date[[:space:]]*,[[:space:]]*1[[:space:]]*,' THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',1)
  FROM definitions
  UNION ALL
  SELECT 'historical_date_selection_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_headers sale
  WHERE (sale.transaction_date_source='CASHIER_SELECTED') IS DISTINCT FROM
    (sale.transaction_date_selected_by IS NOT NULL
      AND sale.transaction_date_selected_at IS NOT NULL AND sale.is_tempo)
  UNION ALL
  SELECT 'posted_sale_financial_event_effective_date',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_headers sale
  JOIN public.financial_events event ON event.company_id=sale.company_id
    AND event.source_table='sales_headers' AND event.source_id=sale.id
    AND event.event_type='SALE_POSTED'
  WHERE sale.document_status='POSTED'
    AND sale.transaction_date_source='CASHIER_SELECTED'
    AND event.event_date IS DISTINCT FROM sale.transaction_date
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
