-- SELECT-only preflight for Customer code allocator collision forward fix.
-- No data, schema, context, or session mutation.

WITH required_versions(version) AS (
  VALUES
    ('20260722010000'),
    ('20260722040000'),
    ('20260730040000'),
    ('20260812220000'),
    ('20260819150000'),
    ('20261008130000'),
    ('20261102160000')
), installed AS (
  SELECT migration.version
  FROM private.kgs_schema_migrations migration
  JOIN required_versions required ON required.version=migration.version
), state AS (
  SELECT
    EXISTS(SELECT 1 FROM private.kgs_schema_migrations migration
      WHERE migration.version='20261102170000') AS ledger,
    to_regprocedure('private.allocate_customer_code(uuid)') IS NOT NULL AS allocator,
    to_regprocedure('private.trg_customer_code_sequence_floor()') IS NOT NULL AS trigger_function
)
SELECT 'customer_code_allocator_preflight_dependency_ledger' AS check_name,
  CASE WHEN (SELECT count(*) FROM installed)=(SELECT count(*) FROM required_versions)
    THEN 'PASS' ELSE 'BLOCKER' END AS status,
  (SELECT count(*) FROM required_versions)-(SELECT count(*) FROM installed) AS violation_rows,
  jsonb_build_object(
    'required',(SELECT jsonb_agg(required.version ORDER BY required.version) FROM required_versions required),
    'installed',(SELECT jsonb_agg(installed.version ORDER BY installed.version) FROM installed)
  ) AS details
UNION ALL
SELECT 'customer_code_allocator_preflight_installation_state',
  CASE
    WHEN NOT state.ledger AND NOT state.allocator AND NOT state.trigger_function THEN 'PASS'
    WHEN state.ledger AND state.allocator AND state.trigger_function THEN 'INSTALLED_CONSISTENT'
    ELSE 'BLOCKER'
  END,
  CASE WHEN (NOT state.ledger AND NOT state.allocator AND NOT state.trigger_function)
          OR (state.ledger AND state.allocator AND state.trigger_function)
    THEN 0 ELSE 1 END,
  jsonb_build_object(
    'classification',CASE
      WHEN NOT state.ledger AND NOT state.allocator AND NOT state.trigger_function THEN 'NOT_INSTALLED'
      WHEN state.ledger AND state.allocator AND state.trigger_function THEN 'INSTALLED_CONSISTENT'
      ELSE 'PARTIAL/INCONSISTENT' END,
    'ledger',state.ledger,'allocator',state.allocator,'triggerFunction',state.trigger_function)
FROM state
UNION ALL
SELECT 'customer_code_allocator_preflight_runtime_anchors',
  CASE WHEN to_regprocedure('public.save_customer(uuid,bigint,text,text,uuid,text,text,text,text,numeric,integer,text,boolean)') IS NOT NULL
         AND to_regprocedure('public.quick_create_pos_customer(text,text,text,text,text)') IS NOT NULL
         AND to_regclass('private.customer_code_sequences') IS NOT NULL
         AND to_regclass('public.customers') IS NOT NULL
         AND EXISTS(SELECT 1 FROM pg_indexes index_def
           WHERE index_def.schemaname='public' AND index_def.indexname='uq_customers_company_normalized_code')
    THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN to_regprocedure('public.save_customer(uuid,bigint,text,text,uuid,text,text,text,text,numeric,integer,text,boolean)') IS NOT NULL
         AND to_regprocedure('public.quick_create_pos_customer(text,text,text,text,text)') IS NOT NULL
         AND to_regclass('private.customer_code_sequences') IS NOT NULL
         AND to_regclass('public.customers') IS NOT NULL
    THEN 0 ELSE 1 END,
  jsonb_build_object(
    'saveCustomer',to_regprocedure('public.save_customer(uuid,bigint,text,text,uuid,text,text,text,text,numeric,integer,text,boolean)') IS NOT NULL,
    'quickCreate',to_regprocedure('public.quick_create_pos_customer(text,text,text,text,text)') IS NOT NULL,
    'sequenceTable',to_regclass('private.customer_code_sequences') IS NOT NULL,
    'customerTable',to_regclass('public.customers') IS NOT NULL)
UNION ALL
SELECT 'customer_code_allocator_preflight_writer_shape',
  CASE WHEN writer.save_old_anchor_count=1 AND writer.quick_old_anchor_count=1
         AND NOT writer.save_new_anchor AND NOT writer.quick_new_anchor
    THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN writer.save_old_anchor_count=1 AND writer.quick_old_anchor_count=1
         AND NOT writer.save_new_anchor AND NOT writer.quick_new_anchor
    THEN 0 ELSE 1 END,
  jsonb_build_object(
    'saveOldAnchorCount',writer.save_old_anchor_count,
    'quickOldAnchorCount',writer.quick_old_anchor_count,
    'saveNewAnchor',writer.save_new_anchor,
    'quickNewAnchor',writer.quick_new_anchor)
FROM (
  SELECT
    (length(definition.save_body)-length(replace(definition.save_body,
      'INSERT INTO private.customer_code_sequences(company_id,next_value)','')))
      /length('INSERT INTO private.customer_code_sequences(company_id,next_value)') AS save_old_anchor_count,
    (length(definition.quick_body)-length(replace(definition.quick_body,
      'INSERT INTO private.customer_code_sequences(company_id,next_value)','')))
      /length('INSERT INTO private.customer_code_sequences(company_id,next_value)') AS quick_old_anchor_count,
    strpos(definition.save_body,'private.allocate_customer_code')>0 AS save_new_anchor,
    strpos(definition.quick_body,'private.allocate_customer_code')>0 AS quick_new_anchor
  FROM (SELECT
    pg_get_functiondef(to_regprocedure(
      'public.save_customer(uuid,bigint,text,text,uuid,text,text,text,text,numeric,integer,text,boolean)')) AS save_body,
    pg_get_functiondef(to_regprocedure(
      'public.quick_create_pos_customer(text,text,text,text,text)')) AS quick_body
  ) definition
) writer
UNION ALL
SELECT 'customer_code_allocator_preflight_counter_inventory',
  'INFO',0,
  jsonb_build_object('companies',COALESCE(jsonb_agg(jsonb_build_object(
    'companyId',company.id,'companyCode',company.company_code,
    'nextValue',sequence.next_value,'maxCanonical',floor.max_canonical,
    'counterCollides',EXISTS(SELECT 1 FROM public.customers customer
      WHERE customer.company_id=company.id
        AND upper(btrim(customer.code))='CUST-'||CASE
          WHEN COALESCE(sequence.next_value,1)<1000000
            THEN lpad(COALESCE(sequence.next_value,1)::text,6,'0')
          ELSE COALESCE(sequence.next_value,1)::text END)
  ) ORDER BY company.company_code),'[]'::jsonb))
FROM public.companies company
LEFT JOIN private.customer_code_sequences sequence ON sequence.company_id=company.id
LEFT JOIN LATERAL (
  SELECT max((substring(upper(btrim(customer.code)) FROM '^CUST-([0-9]{1,18})$'))::bigint) AS max_canonical
  FROM public.customers customer
  WHERE customer.company_id=company.id
    AND upper(btrim(customer.code)) ~ '^CUST-[0-9]{1,18}$'
) floor ON TRUE
UNION ALL
SELECT 'customer_code_allocator_preflight_nonterminal_customer_imports',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  count(*),
  jsonb_build_object('rows',count(*),'statuses',COALESCE(jsonb_agg(DISTINCT job.status)
    FILTER(WHERE job.id IS NOT NULL),'[]'::jsonb))
FROM public.master_import_jobs job
WHERE job.import_type='CUSTOMER'
  AND job.status NOT IN('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED')
UNION ALL
SELECT 'customer_code_allocator_preflight_business_boundary','INFO',0,
  jsonb_build_object(
    'changed',jsonb_build_array('automatic Customer code allocation','Customer counter reconciliation'),
    'preserved',jsonb_build_array('explicit Customer codes','Customer name uniqueness','inactive Customers','parent and Pricelist','permissions and RLS','Sales','Stock/FIFO','Payment','Finance'),
    'mutation','NONE');
