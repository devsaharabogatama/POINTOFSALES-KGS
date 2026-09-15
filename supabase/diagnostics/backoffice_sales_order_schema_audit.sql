-- Backoffice Quotation/SO design audit. READ ONLY.
WITH relation_columns AS (
  SELECT
    table_name,
    column_name,
    ordinal_position,
    data_type,
    udt_name,
    is_nullable,
    column_default
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name IN (
      'sales_headers',
      'sales_items',
      'customers',
      'stores',
      'warehouses',
      'pricelists',
      'company_features',
      'access_permission_catalog'
    )
),
relation_constraints AS (
  SELECT
    relation.relname AS table_name,
    constraint_row.conname AS constraint_name,
    constraint_row.contype AS constraint_type,
    pg_get_constraintdef(constraint_row.oid, true) AS definition
  FROM pg_constraint constraint_row
  JOIN pg_class relation ON relation.oid = constraint_row.conrelid
  JOIN pg_namespace relation_schema ON relation_schema.oid = relation.relnamespace
  WHERE relation_schema.nspname = 'public'
    AND relation.relname IN ('sales_headers', 'sales_items')
),
relation_triggers AS (
  SELECT
    relation.relname AS table_name,
    trigger_row.tgname AS trigger_name,
    pg_get_triggerdef(trigger_row.oid, true) AS definition
  FROM pg_trigger trigger_row
  JOIN pg_class relation ON relation.oid = trigger_row.tgrelid
  JOIN pg_namespace relation_schema ON relation_schema.oid = relation.relnamespace
  WHERE relation_schema.nspname = 'public'
    AND relation.relname IN ('sales_headers', 'sales_items')
    AND NOT trigger_row.tgisinternal
),
routine_state AS (
  SELECT
    routine.oid::regprocedure::text AS signature,
    prosecdef AS security_definer,
    provolatile AS volatility
  FROM pg_proc routine
  JOIN pg_namespace routine_schema ON routine_schema.oid = routine.pronamespace
  WHERE routine_schema.nspname IN ('public', 'private')
    AND (
      routine.proname ILIKE '%sale%'
      OR routine.proname ILIKE '%quotation%'
      OR routine.proname ILIKE '%permission%'
      OR routine.proname ILIKE '%active_company%'
    )
)
SELECT audit.section, audit.details
FROM (
  SELECT 'columns'::text AS section, to_jsonb(column_row) AS details
  FROM relation_columns column_row
  UNION ALL
  SELECT 'constraints', to_jsonb(constraint_row)
  FROM relation_constraints constraint_row
  UNION ALL
  SELECT 'triggers', to_jsonb(trigger_row)
  FROM relation_triggers trigger_row
  UNION ALL
  SELECT 'routines', to_jsonb(routine_row)
  FROM routine_state routine_row
) audit
ORDER BY audit.section, audit.details::text;
