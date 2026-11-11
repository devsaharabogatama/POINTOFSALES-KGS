-- Behavior-neutral Task 5 function source normalization required by the
-- immutable Task 6 raw digest guard when SQL transport stored CRLF body text.
BEGIN;

DO $migration$
DECLARE
  v_routine regprocedure:=
    'public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)'::regprocedure;
  v_definition text;v_normalized text;v_after text;
  v_owner oid;v_acl aclitem[];v_config text[];v_security boolean;
  v_volatility "char";v_parallel "char";v_leakproof boolean;
  v_after_owner oid;v_after_acl aclitem[];v_after_config text[];
  v_after_security boolean;v_after_volatility "char";v_after_parallel "char";
  v_after_leakproof boolean;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(
    '20261110140000:backoffice_ar_function_source_normalization',0));
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261106100000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Task 5 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261110140000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20261110140000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;

  SELECT pg_get_functiondef(proc.oid),proc.proowner,proc.proacl,proc.proconfig,
    proc.prosecdef,proc.provolatile,proc.proparallel,proc.proleakproof
  INTO STRICT v_definition,v_owner,v_acl,v_config,v_security,v_volatility,
    v_parallel,v_leakproof
  FROM pg_proc proc WHERE proc.oid=v_routine;
  v_normalized:=replace(v_definition,E'\r\n',E'\n');
  IF md5(v_normalized)<>'1f3eb44dda2997282789da828e31fa81' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Task 5 Apply semantics changed';
  END IF;
  IF md5(v_definition)<>'1f3eb44dda2997282789da828e31fa81' THEN
    EXECUTE v_normalized;
  END IF;

  SELECT pg_get_functiondef(proc.oid),proc.proowner,proc.proacl,proc.proconfig,
    proc.prosecdef,proc.provolatile,proc.proparallel,proc.proleakproof
  INTO STRICT v_after,v_after_owner,v_after_acl,v_after_config,v_after_security,
    v_after_volatility,v_after_parallel,v_after_leakproof
  FROM pg_proc proc WHERE proc.oid=v_routine;
  IF md5(v_after)<>'1f3eb44dda2997282789da828e31fa81'
    OR v_after_owner IS DISTINCT FROM v_owner
    OR v_after_acl IS DISTINCT FROM v_acl
    OR v_after_config IS DISTINCT FROM v_config
    OR v_after_security IS DISTINCT FROM v_security
    OR v_after_volatility IS DISTINCT FROM v_volatility
    OR v_after_parallel IS DISTINCT FROM v_parallel
    OR v_after_leakproof IS DISTINCT FROM v_leakproof THEN
    RAISE EXCEPTION 'MIGRATION_POSTCONDITION_FAILED: function contract changed';
  END IF;
END
$migration$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261110140000','backoffice_ar_function_source_normalization',
  'Behavior-neutral CRLF-to-LF normalization of the exact Task 5 Apply Credit function so the immutable Task 6 runtime guard is transport-independent; owner, ACL, runtime attributes, AR data, Journals, POS and Stock unchanged');

COMMIT;

