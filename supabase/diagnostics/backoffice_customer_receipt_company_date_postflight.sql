WITH definition AS (
  SELECT pg_get_functiondef(
    'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)'::regprocedure) AS body
)
SELECT 'backoffice_customer_receipt_company_date_postflight_migration_ledger' AS check_name,
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
  abs(count(*)-1)::bigint AS violation_rows,jsonb_build_object('ledgerRows',count(*)) AS details
FROM private.kgs_schema_migrations WHERE version='20261110110000'
UNION ALL
SELECT 'backoffice_customer_receipt_company_date_postflight_runtime_contract',
  CASE WHEN body ILIKE '%v_company_today%'
      AND body ILIKE '%AT TIME ZONE company.timezone%'
      AND body NOT ILIKE '%p_receipt_date>current_date%' THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN body ILIKE '%v_company_today%'
      AND body ILIKE '%AT TIME ZONE company.timezone%'
      AND body NOT ILIKE '%p_receipt_date>current_date%' THEN 0 ELSE 1 END,
  jsonb_build_object('definitionMd5',md5(body),'companyAware',body ILIKE '%v_company_today%',
    'utcGuardRemoved',body NOT ILIKE '%p_receipt_date>current_date%') FROM definition
UNION ALL
SELECT 'backoffice_customer_receipt_company_date_postflight_privilege_contract',
  CASE WHEN has_function_privilege('authenticated',
    'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)','EXECUTE')
    AND NOT has_function_privilege('anon',
    'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)','EXECUTE')
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN has_function_privilege('authenticated',
    'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)','EXECUTE')
    AND NOT has_function_privilege('anon',
    'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)','EXECUTE')
    THEN 0 ELSE 1 END,jsonb_build_object('authenticatedExecute',has_function_privilege(
      'authenticated','public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)','EXECUTE'),
      'anonExecute',has_function_privilege('anon',
      'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)','EXECUTE'))
UNION ALL
SELECT 'backoffice_customer_receipt_company_date_postflight_business_boundary','INFO',0,
  jsonb_build_object('changed',jsonb_build_array('Customer Receipt future-date authority'),
    'preserved',jsonb_build_array('Receipt allocation','Journal','permissions','idempotency',
      'POS direct payment','Stock/FIFO','historical rows'),
    'next','Run rollback-only Task 3 behavior and explicit future-date denial');
