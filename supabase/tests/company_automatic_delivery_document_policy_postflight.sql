-- Company automatic Surat Jalan policy postflight. SELECT-only.
WITH checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    count(*)::BIGINT violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260827153000'
  UNION ALL
  SELECT 'company_delivery_document_policy_schema',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('columnRows',count(*))
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='company_branding_profiles'
    AND column_name='delivery_document_creation_policy'
  UNION ALL
  SELECT 'delivery_fulfillment_snapshot_schema',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('columnRows',count(*))
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='sales_delivery_documents'
    AND column_name='fulfillment_mode' AND is_nullable='NO'
  UNION ALL
  SELECT 'required_automatic_delivery_routines',
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
    abs(4-count(*)),jsonb_build_object('expected',4,'routineRows',count(*))
  FROM (VALUES
    ('private.sales_delivery_document_required(text,text)'),
    ('private.sales_delivery_transition_target(text,text,text,text)'),
    ('public.save_company_document_visibility(bigint,boolean,boolean,boolean,text,text,text)'),
    ('public.get_inventory_delivery_documents(date,date)')
  ) required(signature)
  WHERE to_regprocedure(required.signature) IS NOT NULL
  UNION ALL
  SELECT 'delivery_fulfillment_snapshot_backfill',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('invalidRows',count(*))
  FROM public.sales_delivery_documents delivery
  JOIN public.sales_headers sale ON sale.company_id=delivery.company_id
    AND sale.id=delivery.sales_id
  WHERE (to_jsonb(delivery)->>'fulfillment_mode') IS DISTINCT FROM sale.fulfillment_mode
    OR COALESCE(delivery.snapshot_payload->>'fulfillmentMode','DELIVERY')
      IS DISTINCT FROM (to_jsonb(delivery)->>'fulfillment_mode')
  UNION ALL
  SELECT 'delivery_fulfillment_insert_guard',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('triggerRows',count(*))
  FROM pg_trigger trigger_row
  JOIN pg_class relation ON relation.oid=trigger_row.tgrelid
  JOIN pg_namespace relation_schema ON relation_schema.oid=relation.relnamespace
  WHERE relation_schema.nspname='public' AND relation.relname='sales_delivery_documents'
    AND trigger_row.tgname='trg_sld_validate_delivery_fulfillment'
    AND NOT trigger_row.tgisinternal AND trigger_row.tgenabled<>'D'
  UNION ALL
  SELECT 'pickup_delivery_lifecycle_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('invalidRows',count(*))
  FROM public.sales_delivery_documents delivery
  WHERE (to_jsonb(delivery)->>'fulfillment_mode')='PICKUP' AND (
    delivery.status='DISPATCHED'
    OR delivery.dispatched_at IS NOT NULL OR delivery.dispatched_by IS NOT NULL)
  UNION ALL
  SELECT 'browser_delivery_document_write_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('writableRelations',COALESCE(jsonb_agg(table_name),'[]'::JSONB))
  FROM information_schema.table_privileges
  WHERE grantee='authenticated' AND table_schema='public'
    AND table_name IN('company_branding_profiles','sales_delivery_documents',
      'sales_delivery_lines','sales_headers')
    AND privilege_type IN('INSERT','UPDATE','DELETE')
  UNION ALL
  SELECT 'automatic_delivery_policy_inventory','INFO',0,jsonb_build_object(
    'deliveryOnlyCompanies',count(*) FILTER(WHERE COALESCE(
      to_jsonb(branding)->>'delivery_document_creation_policy',
      'DELIVERY_ONLY')='DELIVERY_ONLY'),
    'allPostedSaleCompanies',count(*) FILTER(WHERE
      to_jsonb(branding)->>'delivery_document_creation_policy'='ALL_POSTED_SALES'),
    'pickupDeliveryDocuments',(SELECT count(*)
      FROM public.sales_delivery_documents delivery_row
      WHERE to_jsonb(delivery_row)->>'fulfillment_mode'='PICKUP'))
  FROM public.companies company
  LEFT JOIN public.company_branding_profiles branding ON branding.company_id=company.id
  WHERE company.status='ACTIVE'
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
