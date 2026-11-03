-- SELECT-only diagnosis for the authenticated POS payment-verification
-- permission regression. This file performs no mutation.

WITH required_migrations(version) AS (
  VALUES ('20261031100000'::text),('20261031110000'::text)
), migration_state AS (
  SELECT required.version,
    EXISTS(SELECT 1 FROM private.kgs_schema_migrations installed
      WHERE installed.version=required.version) AS installed
  FROM required_migrations required
), required_routines(signature,expected_security_definer) AS (
  VALUES
    ('public.post_pos_sale_with_ketul(uuid,bigint,uuid)'::text,true),
    ('public.post_pos_sale_with_pricelist(uuid,bigint,uuid)'::text,false),
    ('public.post_pos_sale(uuid,bigint,uuid)'::text,true),
    ('private.trg_capture_direct_retail_non_cash_payment_requests()'::text,true),
    ('private.capture_direct_retail_non_cash_payment_requests(uuid,uuid,uuid)'::text,true),
    ('private.resolve_direct_retail_sale_payment_function(uuid,uuid,uuid,text)'::text,true),
    ('private.post_sale_return_financial_event_core(uuid,uuid,bigint,uuid)'::text,true),
    ('public.review_sales_payment_verification(uuid,bigint,text,text,uuid)'::text,true)
), routine_state AS (
  SELECT required.signature,required.expected_security_definer,
    proc.oid,proc.prosecdef,
    pg_get_userbyid(proc.proowner) AS owner_name,
    CASE WHEN proc.oid IS NULL THEN false ELSE
      has_function_privilege('authenticated',proc.oid,'EXECUTE') END
      AS authenticated_execute,
    CASE WHEN proc.oid IS NULL THEN false ELSE
      has_table_privilege(pg_get_userbyid(proc.proowner),
        'public.sales_payment_verification_requests','SELECT') END
      AS owner_can_select,
    CASE WHEN proc.oid IS NULL THEN false ELSE
      has_table_privilege(pg_get_userbyid(proc.proowner),
        'public.sales_payment_verification_requests','INSERT') END
      AS owner_can_insert,
    CASE WHEN proc.oid IS NULL THEN false ELSE
      has_table_privilege(pg_get_userbyid(proc.proowner),
        'public.sales_payment_verification_requests','UPDATE') END
      AS owner_can_update
  FROM required_routines required
  LEFT JOIN pg_proc proc ON proc.oid=to_regprocedure(required.signature)
), table_state AS (
  SELECT relation.oid,pg_get_userbyid(relation.relowner) AS owner_name,
    relation.relrowsecurity,relation.relforcerowsecurity,
    has_table_privilege('authenticated',relation.oid,'SELECT') AS authenticated_select,
    has_table_privilege('authenticated',relation.oid,'INSERT') AS authenticated_insert,
    has_table_privilege('authenticated',relation.oid,'UPDATE') AS authenticated_update,
    has_table_privilege('service_role',relation.oid,'SELECT') AS service_select,
    has_table_privilege('service_role',relation.oid,'INSERT') AS service_insert,
    has_table_privilege('service_role',relation.oid,'UPDATE') AS service_update
  FROM pg_class relation
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public'
    AND relation.relname='sales_payment_verification_requests'
), trigger_state AS (
  SELECT trigger.tgname,trigger.tgenabled,
    trigger.tgfoid::regprocedure::text AS function_signature,
    function.prosecdef,pg_get_userbyid(function.proowner) AS function_owner
  FROM pg_trigger trigger
  JOIN pg_class relation ON relation.oid=trigger.tgrelid
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  JOIN pg_proc function ON function.oid=trigger.tgfoid
  WHERE namespace.nspname='public' AND relation.relname='sales_headers'
    AND trigger.tgname='capture_direct_retail_non_cash_payment_requests'
    AND NOT trigger.tgisinternal
), reference_inventory AS (
  SELECT namespace.nspname AS schema_name,proc.proname,
    proc.oid::regprocedure::text AS signature,proc.prosecdef,
    pg_get_userbyid(proc.proowner) AS owner_name
  FROM pg_proc proc
  JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE namespace.nspname IN ('public','private') AND proc.prokind='f'
    AND position('sales_payment_verification_requests'
      IN pg_get_functiondef(proc.oid))>0
), checks AS (
  SELECT 10 AS seq,'pos_retail_non_cash_permission_migration_state'::text check_name,
    CASE WHEN bool_and(installed) AND count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    count(*) FILTER(WHERE NOT installed)::bigint violation_rows,
    jsonb_build_object('migrations',jsonb_agg(jsonb_build_object(
      'version',version,'installed',installed) ORDER BY version)) details
  FROM migration_state
  UNION ALL
  SELECT 20,'pos_retail_non_cash_permission_table_boundary',
    CASE WHEN count(*)=1
      AND bool_and(NOT authenticated_select AND NOT authenticated_insert
        AND NOT authenticated_update AND service_select AND service_insert
        AND service_update) THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)=1
      AND bool_and(NOT authenticated_select AND NOT authenticated_insert
        AND NOT authenticated_update AND service_select AND service_insert
        AND service_update) THEN 0 ELSE 1 END::bigint,
    COALESCE(jsonb_agg(to_jsonb(table_state)),'[]'::jsonb)
  FROM table_state
  UNION ALL
  SELECT 30,'pos_retail_non_cash_permission_routine_boundary',
    CASE WHEN count(*)=8 AND count(*) FILTER(WHERE oid IS NULL)=0
      AND count(*) FILTER(WHERE prosecdef IS DISTINCT FROM expected_security_definer)=0
      AND count(*) FILTER(WHERE expected_security_definer AND NOT owner_can_select)=0
      AND count(*) FILTER(WHERE signature LIKE 'private.capture%' AND NOT owner_can_insert)=0
      AND count(*) FILTER(WHERE signature LIKE 'public.review%' AND NOT owner_can_update)=0
      THEN 'PASS' ELSE 'ROOT_CAUSE' END,
    (count(*) FILTER(WHERE oid IS NULL)
      +count(*) FILTER(WHERE prosecdef IS DISTINCT FROM expected_security_definer)
      +count(*) FILTER(WHERE expected_security_definer AND NOT owner_can_select)
      +count(*) FILTER(WHERE signature LIKE 'private.capture%' AND NOT owner_can_insert)
      +count(*) FILTER(WHERE signature LIKE 'public.review%' AND NOT owner_can_update))::bigint,
    jsonb_build_object('routines',jsonb_agg(jsonb_build_object(
      'signature',signature,'exists',oid IS NOT NULL,'securityDefiner',prosecdef,
      'expectedSecurityDefiner',expected_security_definer,'owner',owner_name,
      'authenticatedExecute',authenticated_execute,
      'ownerCanSelect',owner_can_select,'ownerCanInsert',owner_can_insert,
      'ownerCanUpdate',owner_can_update) ORDER BY signature))
  FROM routine_state
  UNION ALL
  SELECT 40,'pos_retail_non_cash_permission_trigger_boundary',
    CASE WHEN count(*)=1 AND bool_and(tgenabled<>'D' AND prosecdef)
      THEN 'PASS' ELSE 'ROOT_CAUSE' END,
    CASE WHEN count(*)=1 AND bool_and(tgenabled<>'D' AND prosecdef)
      THEN 0 ELSE 1 END::bigint,
    COALESCE(jsonb_agg(to_jsonb(trigger_state)),'[]'::jsonb)
  FROM trigger_state
  UNION ALL
  SELECT 50,'pos_retail_non_cash_permission_reference_inventory','INFO',0::bigint,
    jsonb_build_object('rows',count(*),'routines',COALESCE(jsonb_agg(
      jsonb_build_object('signature',signature,'securityDefiner',prosecdef,
        'owner',owner_name) ORDER BY signature),'[]'::jsonb))
  FROM reference_inventory
  UNION ALL
  SELECT 60,'pos_retail_non_cash_permission_interpretation','INFO',0::bigint,
    jsonb_build_object('mutation','NONE','next',
      'Classify the exact active privilege boundary before any forward migration',
      'forbidden',to_jsonb(ARRAY['grant table access to authenticated',
        'edit applied migration','delete verification requests',
        'bypass Finance verification']::text[]))
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY seq;
