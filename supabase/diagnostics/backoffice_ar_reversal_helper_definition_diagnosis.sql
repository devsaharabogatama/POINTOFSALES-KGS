-- READ ONLY. Run only after reversal-parity preflight reports an unexpected
-- private.ar5_item_allocated(uuid,uuid,date) digest.
BEGIN READ ONLY;

WITH routine AS (
  SELECT proc.oid,pg_get_userbyid(proc.proowner) owner_name,
    proc.prosecdef security_definer,proc.provolatile volatility,
    proc.proparallel parallel_safety,proc.proleakproof leakproof,
    proc.proacl access_control,proc.proconfig runtime_config,
    pg_get_functiondef(proc.oid) definition
  FROM pg_proc proc
  JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE namespace.nspname='private'
    AND proc.oid='private.ar5_item_allocated(uuid,uuid,date)'::regprocedure
), evidence AS (
  SELECT *,
    md5(definition) raw_md5,
    md5(replace(definition,E'\r\n',E'\n')) normalized_md5,
    (length(definition)-length(replace(definition,E'\r\n','')))
      /length(E'\r\n') crlf_count,
    length(replace(definition,E'\r\n',E'\n'))
      -length(replace(replace(definition,E'\r\n',E'\n'),E'\n','')) lf_count
  FROM routine
)
SELECT
  'backoffice_ar_reversal_helper_definition_diagnosis'::text check_name,
  'INFO'::text status,
  CASE WHEN raw_md5='3de3fd3ba6aa98e79db22ef32f1bd0da'
      OR normalized_md5='3de3fd3ba6aa98e79db22ef32f1bd0da'
    THEN 0 ELSE 1 END::bigint violation_rows,
  jsonb_build_object(
    'signature','private.ar5_item_allocated(uuid,uuid,date)',
    'expectedMd5','3de3fd3ba6aa98e79db22ef32f1bd0da',
    'rawMd5',raw_md5,
    'normalizedMd5',normalized_md5,
    'crlfCount',crlf_count,
    'lfCount',lf_count,
    'owner',owner_name,
    'securityDefiner',security_definer,
    'volatility',volatility,
    'parallelSafety',parallel_safety,
    'leakproof',leakproof,
    'accessControl',access_control,
    'runtimeConfig',runtime_config,
    'definition',definition,
    'mutation','NONE') details
FROM evidence;

ROLLBACK;
