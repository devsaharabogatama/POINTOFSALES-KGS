-- Delivery optional contact preflight. SELECT-only.
WITH checks AS (
  SELECT 'delivery_optional_contact_dependency' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('requiredVersion','20260827151000','ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260827151000'
  UNION ALL
  SELECT 'delivery_recipient_name_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidRows',count(*))
  FROM public.sales_delivery_documents
  WHERE COALESCE(btrim(recipient_name),'')=''
  UNION ALL
  SELECT 'delivery_optional_contact_schema_state','SETUP',jsonb_build_object(
    'phoneNullable',(SELECT is_nullable='YES' FROM information_schema.columns
      WHERE table_schema='public' AND table_name='sales_delivery_documents'
        AND column_name='recipient_phone'),
    'addressNullable',(SELECT is_nullable='YES' FROM information_schema.columns
      WHERE table_schema='public' AND table_name='sales_delivery_documents'
        AND column_name='delivery_address'))
  UNION ALL
  SELECT 'delivery_runtime_state','SETUP',jsonb_build_object(
    'ensureRoutineRows',(SELECT count(*) FROM pg_proc routine
      JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
      WHERE namespace.nspname='private' AND routine.proname='ensure_sales_documents'),
    'configureRoutineRows',(SELECT count(*) FROM pg_proc routine
      JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
      WHERE namespace.nspname='public' AND routine.proname='configure_pos_sale_fulfillment'))
  UNION ALL
  SELECT 'delivery_contact_inventory','INFO',jsonb_build_object(
    'documents',count(*),'withoutPhone',count(*) FILTER(
      WHERE COALESCE(btrim(recipient_phone),'')=''),
    'withoutAddress',count(*) FILTER(
      WHERE COALESCE(btrim(delivery_address),'')=''))
  FROM public.sales_delivery_documents
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2
  WHEN 'SETUP' THEN 3 ELSE 4 END,check_name;
