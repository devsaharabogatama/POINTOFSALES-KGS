-- Behavior-neutral normalization of the exact Task 5 effective-allocation
-- helper before the immutable reversal-consumer parity migration.
BEGIN;

DO $migration$
DECLARE
  v_routine regprocedure:=
    'private.ar5_item_allocated(uuid,uuid,date)'::regprocedure;
  v_definition text;v_normalized text;v_after text;
  v_owner oid;v_acl aclitem[];v_config text[];v_security boolean;
  v_volatility "char";v_parallel "char";v_leakproof boolean;
  v_after_owner oid;v_after_acl aclitem[];v_after_config text[];
  v_after_security boolean;v_after_volatility "char";v_after_parallel "char";
  v_after_leakproof boolean;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(
    '20261110150000:backoffice_ar_reversal_helper_source_normalization',0));
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261106100000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261110100000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261110140000') THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: Task 5, Task 6 and source bridge required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261110130000') THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: reversal parity already installed';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261110150000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20261110150000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;

  SELECT pg_get_functiondef(proc.oid),proc.proowner,proc.proacl,proc.proconfig,
    proc.prosecdef,proc.provolatile,proc.proparallel,proc.proleakproof
  INTO STRICT v_definition,v_owner,v_acl,v_config,v_security,v_volatility,
    v_parallel,v_leakproof
  FROM pg_proc proc WHERE proc.oid=v_routine;
  v_normalized:=replace(v_definition,E'\r\n',E'\n');
  IF md5(v_normalized)<>'3de3fd3ba6aa98e79db22ef32f1bd0da' THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: effective allocation semantics changed';
  END IF;
  IF md5(v_definition)<>'3de3fd3ba6aa98e79db22ef32f1bd0da' THEN
    EXECUTE v_normalized;
  END IF;

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
    RAISE EXCEPTION
      'MIGRATION_POSTCONDITION_FAILED: effective allocation contract changed';
  END IF;
END
$migration$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261110150000',
  'backoffice_ar_reversal_helper_source_normalization',
  'Behavior-neutral mixed-CRLF-to-LF normalization of the exact Task 5 effective-allocation helper before immutable reversal-consumer parity; owner, ACL, runtime attributes, AR data, Journals, Customer Balance, POS and Stock unchanged');

COMMIT;
