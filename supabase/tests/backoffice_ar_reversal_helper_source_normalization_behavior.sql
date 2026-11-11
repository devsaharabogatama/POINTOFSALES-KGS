-- Rollback-only exact mixed-line-ending normalization behavior.
BEGIN;

DO $test$
DECLARE
  v_routine regprocedure:=
    'private.ar5_item_allocated(uuid,uuid,date)'::regprocedure;
  v_before text;v_prefix text;v_tail text;v_mixed text;v_normalized text;v_after text;
  v_owner oid;v_acl aclitem[];v_config text[];v_security boolean;
  v_volatility "char";v_parallel "char";v_leakproof boolean;
  v_after_owner oid;v_after_acl aclitem[];v_after_config text[];
  v_after_security boolean;v_after_volatility "char";v_after_parallel "char";
  v_after_leakproof boolean;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261110150000') THEN
    RAISE EXCEPTION
      'TEST_PRECONDITION_FAILED: helper normalization migration required';
  END IF;
  SELECT pg_get_functiondef(proc.oid),proc.proowner,proc.proacl,proc.proconfig,
    proc.prosecdef,proc.provolatile,proc.proparallel,proc.proleakproof
  INTO STRICT v_before,v_owner,v_acl,v_config,v_security,v_volatility,
    v_parallel,v_leakproof
  FROM pg_proc proc WHERE proc.oid=v_routine;
  IF md5(v_before)<>'3de3fd3ba6aa98e79db22ef32f1bd0da' THEN
    RAISE EXCEPTION
      'TEST_PRECONDITION_FAILED: canonical LF helper source required';
  END IF;

  v_prefix:=split_part(v_before,'AS $function$',1)||'AS $function$';
  v_tail:=substr(v_before,length(v_prefix)+1);
  v_mixed:=v_prefix
    ||replace(left(v_tail,length(v_tail)-1),E'\n',E'\r\n')
    ||right(v_tail,1);
  IF md5(v_mixed)<>'63d4690aa26036ab394907255d121a42'
    OR (length(v_mixed)-length(replace(v_mixed,E'\r\n','')))
      /length(E'\r\n')<>10 THEN
    RAISE EXCEPTION
      'TEST_FAILED: exact Production mixed-line-ending fixture not reproduced';
  END IF;
  EXECUTE v_mixed;
  SELECT pg_get_functiondef(v_routine) INTO v_after;
  v_normalized:=replace(v_after,E'\r\n',E'\n');
  IF md5(v_after)<>'63d4690aa26036ab394907255d121a42'
    OR md5(v_normalized)<>'3de3fd3ba6aa98e79db22ef32f1bd0da' THEN
    RAISE EXCEPTION
      'TEST_FAILED: active mixed source did not normalize to canonical contract';
  END IF;
  EXECUTE v_normalized;

  SELECT pg_get_functiondef(proc.oid),proc.proowner,proc.proacl,proc.proconfig,
    proc.prosecdef,proc.provolatile,proc.proparallel,proc.proleakproof
  INTO STRICT v_after,v_after_owner,v_after_acl,v_after_config,v_after_security,
    v_after_volatility,v_after_parallel,v_after_leakproof
  FROM pg_proc proc WHERE proc.oid=v_routine;
  IF md5(v_after)<>'3de3fd3ba6aa98e79db22ef32f1bd0da'
    OR v_after_owner IS DISTINCT FROM v_owner
    OR v_after_acl IS DISTINCT FROM v_acl
    OR v_after_config IS DISTINCT FROM v_config
    OR v_after_security IS DISTINCT FROM v_security
    OR v_after_volatility IS DISTINCT FROM v_volatility
    OR v_after_parallel IS DISTINCT FROM v_parallel
    OR v_after_leakproof IS DISTINCT FROM v_leakproof THEN
    RAISE EXCEPTION 'TEST_FAILED: normalized helper contract changed';
  END IF;
END
$test$;

SELECT 'backoffice_ar_reversal_helper_source_normalization_behavior' check_name,
  'PASS' status,0 violation_rows,jsonb_build_object('tested',ARRAY[
    'installed exact helper compatibility migration',
    'exact Production mixed-line-ending digest and CRLF count reproduced',
    'LF normalization restores exact canonical raw digest',
    'owner, ACL, runtime configuration and routine attributes preserved',
    'all test effects rolled back']) details;

ROLLBACK;
