-- Make Sales Return Transfer destination/reference optional while preserving
-- method, amount, settlement, Stock/FIFO, Finance and approval boundaries.
BEGIN;
SET LOCAL lock_timeout='5s';

DO $guard$
DECLARE
  v_definition text;
  v_constraint text;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260803010000','20260811150000',
        '20260829110000','20261102100000'))<>4 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Sales Return dependency chain incomplete';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261102110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20261102110000';
  END IF;
  IF to_regprocedure(
      'private.save_sales_return_draft_sld_r4_core(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb)'
    ) IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Return Draft core missing';
  END IF;
  SELECT pg_get_functiondef(
    'private.save_sales_return_draft_sld_r4_core(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb)'::regprocedure
  ) INTO v_definition;
  IF md5(v_definition)<>'af21deff47f6947f9e5f7cfb994bb1cb'
    OR v_definition NOT LIKE '%TRANSFER_REFUND_REFERENCE_REQUIRED%'
    OR v_definition NOT LIKE '%odr6d_returnable_sales_detail_quantity%'
    OR v_definition NOT LIKE '%btrim(v_refund->>''transferDestination'') END,%'
    OR v_definition NOT LIKE '%btrim(v_refund->>''transferReference'') END,%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Return Draft core changed';
  END IF;
  SELECT pg_get_constraintdef(constraint_row.oid,true) INTO v_constraint
  FROM pg_constraint constraint_row
  JOIN pg_class relation ON relation.oid=constraint_row.conrelid
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public'
    AND relation.relname='sales_return_refunds'
    AND constraint_row.conname='sales_return_refund_transfer_contract'
    AND constraint_row.contype='c';
  IF v_constraint IS NULL
    OR v_constraint NOT LIKE '%btrim(transfer_destination)%'
    OR v_constraint NOT LIKE '%btrim(transfer_reference)%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Return Transfer constraint changed';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
END
$guard$;

ALTER TABLE public.sales_return_refunds
  DROP CONSTRAINT sales_return_refund_transfer_contract,
  ADD CONSTRAINT sales_return_refund_transfer_contract CHECK (
    (
      payment_method_type_snapshot='TRANSFER'
      AND (transfer_destination IS NULL OR btrim(transfer_destination)<>'')
      AND (transfer_reference IS NULL OR btrim(transfer_reference)<>'')
    ) OR (
      payment_method_type_snapshot<>'TRANSFER'
      AND transfer_destination IS NULL
      AND transfer_reference IS NULL
    )
  );

COMMENT ON CONSTRAINT sales_return_refund_transfer_contract
  ON public.sales_return_refunds IS
  'Transfer destination/reference are optional audit metadata; blanks are invalid and canonical runtime normalizes them to NULL. Non-Transfer refunds remain metadata-free.';

DO $patch$
DECLARE
  v_definition text;
  v_start integer;
  v_relative_end integer;
  v_validation text;
  v_destination_old text:='btrim(v_refund->>''transferDestination'') END,';
  v_destination_new text:='NULLIF(btrim(v_refund->>''transferDestination''),'''') END,';
  v_reference_old text:='btrim(v_refund->>''transferReference'') END,';
  v_reference_new text:='NULLIF(btrim(v_refund->>''transferReference''),'''') END,';
BEGIN
  SELECT pg_get_functiondef(
    'private.save_sales_return_draft_sld_r4_core(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb)'::regprocedure
  ) INTO v_definition;
  IF md5(v_definition)<>'af21deff47f6947f9e5f7cfb994bb1cb' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Return Draft core digest changed';
  END IF;

  v_start:=strpos(v_definition,
    'IF v_method.method_type = ''TRANSFER'' AND (');
  IF v_start=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Transfer validation start missing';
  END IF;
  v_validation:=substr(v_definition,v_start);
  v_relative_end:=strpos(v_validation,'END IF;');
  IF v_relative_end=0 OR v_validation NOT LIKE
      '%TRANSFER_REFUND_REFERENCE_REQUIRED%END IF;%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Transfer validation end missing';
  END IF;
  v_definition:=substr(v_definition,1,v_start-1)
    ||substr(v_validation,v_relative_end+length('END IF;'));

  IF (length(v_definition)-length(replace(v_definition,v_destination_old,'')))
        /length(v_destination_old)<>1
    OR (length(v_definition)-length(replace(v_definition,v_reference_old,'')))
        /length(v_reference_old)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Transfer insert normalization anchor changed';
  END IF;
  v_definition:=replace(v_definition,v_destination_old,v_destination_new);
  v_definition:=replace(v_definition,v_reference_old,v_reference_new);

  IF v_definition LIKE '%TRANSFER_REFUND_REFERENCE_REQUIRED%'
    OR v_definition NOT LIKE '%NULLIF(btrim(v_refund->>''transferDestination''),'''') END,%'
    OR v_definition NOT LIKE '%NULLIF(btrim(v_refund->>''transferReference''),'''') END,%'
    OR v_definition NOT LIKE '%odr6d_returnable_sales_detail_quantity%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: corrected Return Draft core invalid';
  END IF;
  EXECUTE v_definition;
END
$patch$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261102110000','pos_sales_return_optional_transfer_metadata',
  'Make Sales Return Transfer destination/reference/proof metadata optional, normalize blanks to NULL, and preserve settlement, Stock/FIFO, Finance and approval routing');

NOTIFY pgrst,'reload schema';
COMMIT;
