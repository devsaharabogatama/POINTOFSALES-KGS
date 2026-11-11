-- READ ONLY. Export the exact active Task 5 Apply function for semantic diff.
WITH target AS (
  SELECT to_regprocedure(
    'public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)') routine
), definition AS (
  SELECT proc.oid routine, pg_get_functiondef(proc.oid) function_definition,
    pg_get_userbyid(proc.proowner) owner_name, proc.prosecdef security_definer,
    proc.proconfig runtime_config, proc.proacl access_control
  FROM target
  JOIN pg_proc proc ON proc.oid=target.routine
)
SELECT
  'backoffice_ar_credit_note_replacement_apply_definition_diagnosis' check_name,
  CASE WHEN count(*)=1 THEN 'INFO' ELSE 'ROOT_CAUSE' END status,
  CASE WHEN count(*)=1 THEN 0 ELSE 1 END violation_rows,
  CASE WHEN count(*)=1 THEN jsonb_build_object(
    'signature','public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)',
    'definitionMd5',md5(max(function_definition)),
    'owner',max(owner_name),
    'securityDefiner',bool_and(security_definer),
    'runtimeConfig',to_jsonb(max(runtime_config::text)),
    'accessControl',to_jsonb(max(access_control::text)),
    'functionDefinition',max(function_definition),
    'mutation','NONE')
  ELSE jsonb_build_object(
    'error','ACTIVE_FUNCTION_NOT_FOUND',
    'mutation','NONE') END details
FROM definition;
