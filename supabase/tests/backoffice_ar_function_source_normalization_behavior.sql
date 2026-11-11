-- Rollback-only transport normalization behavior.
BEGIN;

DO $test$
DECLARE
  v_routine regprocedure:=
    'public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)'::regprocedure;
  v_before text;v_crlf text;v_normalized text;v_after text;
  v_owner oid;v_acl aclitem[];v_config text[];v_security boolean;
  v_after_owner oid;v_after_acl aclitem[];v_after_config text[];v_after_security boolean;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261110140000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: normalization migration required';
  END IF;
  SELECT pg_get_functiondef(proc.oid),proc.proowner,proc.proacl,proc.proconfig,proc.prosecdef
  INTO STRICT v_before,v_owner,v_acl,v_config,v_security
  FROM pg_proc proc WHERE proc.oid=v_routine;
  IF md5(v_before)<>'1f3eb44dda2997282789da828e31fa81' THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical LF source required';
  END IF;

  v_crlf:=replace(v_before,E'\n',E'\r\n');
  EXECUTE v_crlf;
  SELECT pg_get_functiondef(v_routine) INTO v_after;
  v_normalized:=replace(v_after,E'\r\n',E'\n');
  IF md5(v_normalized)<>'1f3eb44dda2997282789da828e31fa81' THEN
    RAISE EXCEPTION 'TEST_FAILED: CRLF source did not normalize to canonical contract';
  END IF;
  EXECUTE v_normalized;

  SELECT pg_get_functiondef(proc.oid),proc.proowner,proc.proacl,proc.proconfig,proc.prosecdef
  INTO STRICT v_after,v_after_owner,v_after_acl,v_after_config,v_after_security
  FROM pg_proc proc WHERE proc.oid=v_routine;
  IF md5(v_after)<>'1f3eb44dda2997282789da828e31fa81'
    OR v_after_owner IS DISTINCT FROM v_owner
    OR v_after_acl IS DISTINCT FROM v_acl
    OR v_after_config IS DISTINCT FROM v_config
    OR v_after_security IS DISTINCT FROM v_security THEN
    RAISE EXCEPTION 'TEST_FAILED: normalized routine contract changed';
  END IF;
END
$test$;

SELECT 'backoffice_ar_function_source_normalization_behavior' check_name,
  'PASS' status,0 violation_rows,jsonb_build_object('tested',ARRAY[
    'installed exact compatibility migration',
    'CRLF representation reproduces normalized canonical digest',
    'LF normalization restores exact raw digest',
    'owner, ACL, runtime configuration and security-definer preserved',
    'all test effects rolled back']) details;

ROLLBACK;

