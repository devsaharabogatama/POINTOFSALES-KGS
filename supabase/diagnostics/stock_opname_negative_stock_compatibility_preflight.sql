-- Stock Opname compatibility with signed system stock preflight.
-- SAFETY: SELECT-only.

WITH checks(check_name,status,details) AS (
  SELECT 'migration_dependency',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('requiredVersion','20260902100000','ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260902100000'
  UNION ALL
  SELECT 'stock_opname_quantity_constraint_state',
    CASE WHEN count(*)=1 THEN 'SETUP' ELSE 'BLOCKER' END,
    jsonb_build_object('legacyConstraintRows',count(*))
  FROM pg_constraint
  WHERE conrelid='public.stock_opname_details'::regclass
    AND conname='stock_opname_details_quantity_nonnegative'
    AND pg_get_constraintdef(oid) ILIKE '%system_qty_at_start%>=%0%'
  UNION ALL
  SELECT 'negative_stock_opname_scope','INFO',jsonb_build_object(
    'pairs',count(*),'companies',count(DISTINCT stock.company_id),
    'minimumStock',min(stock.stock_qty))
  FROM public.product_stocks stock
  JOIN public.products product ON product.company_id=stock.company_id
    AND product.id=stock.product_id AND product.is_active
    AND NOT product.is_bundle
  WHERE stock.stock_qty<0
  UNION ALL
  SELECT 'existing_stock_opname_physical_quantity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('negativePhysicalRows',count(*))
  FROM public.stock_opname_details WHERE physical_qty<0
)
SELECT * FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'SETUP' THEN 2
  WHEN 'PASS' THEN 3 ELSE 4 END,check_name;
