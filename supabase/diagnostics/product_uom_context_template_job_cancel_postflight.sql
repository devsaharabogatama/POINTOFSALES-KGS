-- SELECT-only postflight: Product-UOM contextual template and job cancellation.
WITH checks AS (
  SELECT 'contextual_product_uom_exchange_routines' check_name,
    CASE WHEN count(*) FILTER(WHERE signature IS NOT NULL)=3
      THEN 'PASS' ELSE 'FAIL' END status,
    jsonb_build_object('routineRows',count(*) FILTER(WHERE signature IS NOT NULL),
      'expected',3) details
  FROM (VALUES
    (to_regprocedure('private.prd_product_uom_exchange_rows(uuid)')),
    (to_regprocedure('public.export_inventory_product_uom_placeholders()')),
    (to_regprocedure('public.get_inventory_product_uom_import_template()'))
  ) required(signature)
  UNION ALL
  SELECT 'master_import_cancel_routines',
    CASE WHEN count(*) FILTER(WHERE signature IS NOT NULL)=3
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('routineRows',count(*) FILTER(WHERE signature IS NOT NULL),
      'expected',3)
  FROM (VALUES
    (to_regprocedure('private.cancel_master_import_job_core(uuid,bigint,text)')),
    (to_regprocedure('public.cancel_master_import_job(uuid,bigint,text)')),
    (to_regprocedure('public.cleanup_stale_master_import_jobs()'))
  ) required(signature)
  UNION ALL
  SELECT 'master_import_cancel_rpc_boundary',
    CASE WHEN signature IS NOT NULL
      AND NOT has_function_privilege('anon',signature,'EXECUTE')
      AND has_function_privilege('authenticated',signature,'EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object(
      'anonRows',CASE WHEN signature IS NOT NULL
        AND has_function_privilege('anon',signature,'EXECUTE') THEN 1 ELSE 0 END,
      'authenticatedRows',CASE WHEN signature IS NOT NULL
        AND has_function_privilege('authenticated',signature,'EXECUTE') THEN 1 ELSE 0 END)
  FROM (SELECT to_regprocedure(
    'public.cancel_master_import_job(uuid,bigint,text)') signature) resolved
  UNION ALL
  SELECT 'stale_unvalidated_cleanup_contract',
    CASE WHEN definition LIKE '%interval ''15 minutes''%'
      AND definition LIKE '%auto_stale_unvalidated%'
      AND definition LIKE '%uploaded_by=v_actor%'
      AND definition LIKE '%acp_require_product_import_if_needed%'
      AND definition LIKE '%acp_require_customer_import_if_needed%'
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('routineRows',CASE WHEN definition='' THEN 0 ELSE 1 END)
  FROM (SELECT COALESCE(lower(routine.prosrc),'') definition
    FROM (SELECT to_regprocedure(
      'public.cleanup_stale_master_import_jobs()') signature) resolved
    LEFT JOIN pg_proc routine ON routine.oid=resolved.signature) source
  UNION ALL
  SELECT 'product_uom_reference_input_contract',
    CASE WHEN definition LIKE '%''reference''%'
      AND definition LIKE '%''input''%'
      AND definition LIKE '%weight_reference_uom_id%'
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('routineRows',CASE WHEN definition='' THEN 0 ELSE 1 END)
  FROM (SELECT COALESCE(lower(routine.prosrc),'') definition
    FROM (SELECT to_regprocedure(
      'private.prd_product_uom_exchange_rows(uuid)') signature) resolved
    LEFT JOIN pg_proc routine ON routine.oid=resolved.signature) source
  UNION ALL
  SELECT 'product_uom_validation_dispatch',
    CASE WHEN definition LIKE '%validate_product_uom_import_job%'
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('routineRows',CASE WHEN definition='' THEN 0 ELSE 1 END)
  FROM (SELECT COALESCE(pg_get_functiondef(to_regprocedure(
    'public.validate_master_import_job(uuid,bigint)')),'') definition) resolved
  UNION ALL
  SELECT 'migration_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260821100000'
), inventory AS (
  SELECT 'master_import_nonterminal_inventory' check_name,'INFO' status,
    jsonb_build_object('uploaded',count(*) FILTER(WHERE status='UPLOADED'),
      'mapped',count(*) FILTER(WHERE status='MAPPED'),
      'validated',count(*) FILTER(WHERE status='VALIDATED'),
      'ready',count(*) FILTER(WHERE status='READY'),
      'processing',count(*) FILTER(WHERE status='PROCESSING')) details
  FROM public.master_import_jobs
)
SELECT check_name,status,details FROM (
  SELECT * FROM checks UNION ALL SELECT * FROM inventory
) result ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
