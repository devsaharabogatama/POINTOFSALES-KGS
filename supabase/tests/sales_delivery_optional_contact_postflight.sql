-- Delivery optional contact postflight. SELECT-only.
WITH constraint_state AS (
  SELECT constraint_name,pg_get_constraintdef(constraint_oid) definition
  FROM (SELECT catalog_constraint.oid constraint_oid,
      catalog_constraint.conname constraint_name
    FROM pg_constraint catalog_constraint
    JOIN pg_class relation ON relation.oid=catalog_constraint.conrelid
    JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
    WHERE namespace.nspname='public' AND (
      (relation.relname='sales_headers'
        AND catalog_constraint.conname='sales_headers_fulfillment_shape_check') OR
      (relation.relname='sales_delivery_documents'
        AND catalog_constraint.conname='sales_delivery_document_identity_check'))) source
),checks AS (
  SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260827152000'
  UNION ALL
  SELECT 'delivery_optional_contact_nullability',
    CASE WHEN count(*) FILTER(WHERE column_name IN('recipient_phone','delivery_address')
      AND is_nullable='YES')=2 THEN 'PASS' ELSE 'FAIL' END,
    2-count(*) FILTER(WHERE column_name IN('recipient_phone','delivery_address')
      AND is_nullable='YES'),jsonb_build_object('expected',2,
      'nullableRows',count(*) FILTER(WHERE is_nullable='YES'))
  FROM information_schema.columns WHERE table_schema='public'
    AND table_name='sales_delivery_documents'
    AND column_name IN('recipient_phone','delivery_address')
  UNION ALL
  SELECT 'delivery_name_only_constraint_contract',
    CASE WHEN count(*)=2
      AND count(*) FILTER(WHERE constraint_name='sales_headers_fulfillment_shape_check'
        AND definition ILIKE '%document_status%'
        AND definition ILIKE '%delivery_recipient_name%'
        AND regexp_count(definition,'delivery_recipient_phone')=1
        AND regexp_count(definition,'delivery_address')=1)=1
      AND count(*) FILTER(WHERE constraint_name='sales_delivery_document_identity_check'
        AND definition ILIKE '%recipient_name%'
        AND regexp_count(definition,'recipient_phone')=0
        AND regexp_count(definition,'delivery_address')=0)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=2
      AND count(*) FILTER(WHERE constraint_name='sales_headers_fulfillment_shape_check'
        AND definition ILIKE '%document_status%'
        AND definition ILIKE '%delivery_recipient_name%'
        AND regexp_count(definition,'delivery_recipient_phone')=1
        AND regexp_count(definition,'delivery_address')=1)=1
      AND count(*) FILTER(WHERE constraint_name='sales_delivery_document_identity_check'
        AND definition ILIKE '%recipient_name%'
        AND regexp_count(definition,'recipient_phone')=0
        AND regexp_count(definition,'delivery_address')=0)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('constraintRows',count(*)) FROM constraint_state
  UNION ALL
  SELECT 'delivery_name_only_runtime_contract',
    CASE WHEN count(*)=2
      AND bool_and(pg_get_functiondef(routine.oid) ILIKE '%require_delivery_recipient_name%')
      AND bool_and(pg_get_functiondef(routine.oid) NOT ILIKE
        '%COALESCE(btrim(v_sale.delivery_recipient_phone)%') THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=2
      AND bool_and(pg_get_functiondef(routine.oid) ILIKE '%require_delivery_recipient_name%')
      AND bool_and(pg_get_functiondef(routine.oid) NOT ILIKE
        '%COALESCE(btrim(v_sale.delivery_recipient_phone)%') THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE (namespace.nspname='private' AND routine.proname='ensure_sales_documents')
     OR (namespace.nspname='public' AND routine.proname='configure_pos_sale_fulfillment')
  UNION ALL
  SELECT 'delivery_recipient_name_integrity',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.sales_delivery_documents WHERE COALESCE(btrim(recipient_name),'')=''
  UNION ALL
  SELECT 'delivery_optional_contact_inventory','INFO',0,jsonb_build_object(
    'documents',count(*),'withoutPhone',count(*) FILTER(
      WHERE COALESCE(btrim(recipient_phone),'')=''),
    'withoutAddress',count(*) FILTER(
      WHERE COALESCE(btrim(delivery_address),'')=''))
  FROM public.sales_delivery_documents
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
