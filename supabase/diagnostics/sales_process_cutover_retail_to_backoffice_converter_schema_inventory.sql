-- Read-only schema inventory used to diagnose the migration 41 fixture gate.
WITH checks AS (
  SELECT 'companies_column_inventory'::text check_name,'INFO'::text status,
    0::bigint violation_rows,
    jsonb_build_object('columns',COALESCE(jsonb_agg(column_name ORDER BY ordinal_position),'[]')) details
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='companies'
  UNION ALL
  SELECT 'fixture_relation_inventory','INFO',0::bigint,jsonb_build_object(
    'companies',(SELECT count(*) FROM public.companies WHERE status='ACTIVE'),
    'stores',(SELECT count(*) FROM public.stores WHERE status='ACTIVE'),
    'terminals',(SELECT count(*) FROM public.pos_terminals WHERE status='ACTIVE'),
    'saleSourceWarehouses',(SELECT count(*) FROM public.warehouses
      WHERE is_active AND is_sale_source),
    'customers',(SELECT count(*) FROM public.customers WHERE is_active),
    'productUoms',(SELECT count(*) FROM public.product_uoms
      WHERE is_active AND sales_allowed AND factor_to_base>0 AND sale_price>0),
    'featureRows',(SELECT count(*) FROM public.company_features
      WHERE feature_code='backoffice_delivered_qty_sales_enabled'))
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY check_name;
