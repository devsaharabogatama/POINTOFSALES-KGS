-- SELECT-only postflight for migration 20261102170000.

SELECT 'customer_code_allocator_postflight_migration_ledger' AS check_name,
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
  abs(count(*)-1) AS violation_rows,
  jsonb_build_object('ledgerRows',count(*)) AS details
FROM private.kgs_schema_migrations migration
WHERE migration.version='20261102170000'
UNION ALL
SELECT 'customer_code_allocator_postflight_runtime_contract',
  CASE WHEN allocator.oid IS NOT NULL
         AND save_writer.definition LIKE '%private.allocate_customer_code(v_company_id)%'
         AND quick_writer.definition LIKE '%private.allocate_customer_code(v_company)%'
         AND trigger_state.rows=1 AND trigger_state.enabled='O'
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN allocator.oid IS NOT NULL
         AND save_writer.definition LIKE '%private.allocate_customer_code(v_company_id)%'
         AND quick_writer.definition LIKE '%private.allocate_customer_code(v_company)%'
         AND trigger_state.rows=1 AND trigger_state.enabled='O'
    THEN 0 ELSE 1 END,
  jsonb_build_object(
    'allocator',allocator.oid IS NOT NULL,
    'saveCustomerUsesAllocator',save_writer.definition LIKE '%private.allocate_customer_code(v_company_id)%',
    'quickCreateUsesAllocator',quick_writer.definition LIKE '%private.allocate_customer_code(v_company)%',
    'triggerRows',trigger_state.rows,'triggerEnabled',trigger_state.enabled)
FROM (SELECT to_regprocedure('private.allocate_customer_code(uuid)') AS oid) allocator
CROSS JOIN LATERAL (SELECT pg_get_functiondef(to_regprocedure(
  'public.save_customer(uuid,bigint,text,text,uuid,text,text,text,text,numeric,integer,text,boolean)')) AS definition) save_writer
CROSS JOIN LATERAL (SELECT pg_get_functiondef(to_regprocedure(
  'public.quick_create_pos_customer(text,text,text,text,text)')) AS definition) quick_writer
CROSS JOIN LATERAL (
  SELECT count(*) AS rows,max(pg_trg.tgenabled::text) AS enabled
  FROM pg_trigger pg_trg
  WHERE pg_trg.tgrelid='public.customers'::regclass
    AND pg_trg.tgname='trg_customers_code_sequence_floor'
    AND NOT pg_trg.tgisinternal
) trigger_state
UNION ALL
SELECT 'customer_code_allocator_postflight_counter_floor',
  CASE WHEN count(*) FILTER(WHERE inventory.invalid)>0 THEN 'FAIL' ELSE 'PASS' END,
  count(*) FILTER(WHERE inventory.invalid),
  jsonb_build_object('companies',count(*),'invalid',COALESCE(jsonb_agg(
    jsonb_build_object('companyCode',inventory.company_code,
      'nextValue',inventory.next_value,'maxCanonical',inventory.max_canonical))
    FILTER(WHERE inventory.invalid),'[]'::jsonb))
FROM (
  SELECT company.company_code,sequence.next_value,
    COALESCE(floor.max_canonical,0) AS max_canonical,
    sequence.next_value IS NULL
      OR sequence.next_value<=COALESCE(floor.max_canonical,0) AS invalid
  FROM public.companies company
  LEFT JOIN private.customer_code_sequences sequence ON sequence.company_id=company.id
  LEFT JOIN LATERAL (
    SELECT max((substring(upper(btrim(customer.code))
      FROM '^CUST-([0-9]{1,18})$'))::bigint) AS max_canonical
    FROM public.customers customer
    WHERE customer.company_id=company.id
      AND upper(btrim(customer.code)) ~ '^CUST-[0-9]{1,18}$'
  ) floor ON TRUE
) inventory
UNION ALL
SELECT 'customer_code_allocator_postflight_privilege_contract',
  CASE WHEN NOT has_function_privilege('authenticated','private.allocate_customer_code(uuid)','EXECUTE')
         AND NOT has_function_privilege('anon','private.allocate_customer_code(uuid)','EXECUTE')
         AND has_function_privilege('authenticated','public.quick_create_pos_customer(text,text,text,text,text)','EXECUTE')
         AND NOT has_function_privilege('authenticated',
           'public.save_customer(uuid,bigint,text,text,uuid,text,text,text,text,numeric,integer,text,boolean)','EXECUTE')
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN NOT has_function_privilege('authenticated','private.allocate_customer_code(uuid)','EXECUTE')
         AND NOT has_function_privilege('anon','private.allocate_customer_code(uuid)','EXECUTE')
         AND has_function_privilege('authenticated','public.quick_create_pos_customer(text,text,text,text,text)','EXECUTE')
         AND NOT has_function_privilege('authenticated',
           'public.save_customer(uuid,bigint,text,text,uuid,text,text,text,text,numeric,integer,text,boolean)','EXECUTE')
    THEN 0 ELSE 1 END,
  jsonb_build_object(
    'allocatorAuthenticated',has_function_privilege('authenticated','private.allocate_customer_code(uuid)','EXECUTE'),
    'allocatorAnon',has_function_privilege('anon','private.allocate_customer_code(uuid)','EXECUTE'),
    'quickCreateAuthenticated',has_function_privilege('authenticated','public.quick_create_pos_customer(text,text,text,text,text)','EXECUTE'),
    'baseSaveAuthenticated',has_function_privilege('authenticated',
      'public.save_customer(uuid,bigint,text,text,uuid,text,text,text,text,numeric,integer,text,boolean)','EXECUTE'))
UNION ALL
SELECT 'customer_code_allocator_postflight_business_boundary','INFO',0,
  jsonb_build_object(
    'changed',jsonb_build_array('automatic POS Customer code','automatic Backoffice Customer code','monotonic counter floor'),
    'preserved',jsonb_build_array('explicit Customer codes','inactive Customer identity','name uniqueness','parent/Pricelist','permission/RLS','Sales','Stock/FIFO','Payment','Finance'),
    'next','Run rollback-only behavior, then authenticated POS and Backoffice smoke');
