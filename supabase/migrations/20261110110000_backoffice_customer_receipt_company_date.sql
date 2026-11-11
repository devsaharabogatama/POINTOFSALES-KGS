BEGIN;

DO $guard$
DECLARE v_definition text;v_old text;v_count integer;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261110110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20261110110000';
  END IF;
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20261105110000','20261110100000'))<>2 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: dependency ledger incomplete';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))
    OR EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance/offline work';
  END IF;
  SELECT pg_get_functiondef(
    'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)'::regprocedure)
  INTO STRICT v_definition;
  IF md5(v_definition)<>'f77bd1009a5c15f063748981ad48e77d' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Receipt saver anchor changed';
  END IF;
  v_old:='v_client_key uuid;v_due date;v_is_new boolean:=p_document_id IS NULL;';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: declaration anchor changed'; END IF;
  v_old:='IF p_receipt_date>current_date THEN RAISE EXCEPTION ''CUSTOMER_RECEIPT_DATE_FUTURE''; END IF;';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: date guard anchor changed'; END IF;
END
$guard$;

DO $patch$
DECLARE v_definition text;v_old text;v_new text;
BEGIN
  SELECT pg_get_functiondef(
    'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)'::regprocedure)
  INTO STRICT v_definition;
  v_old:='v_client_key uuid;v_due date;v_is_new boolean:=p_document_id IS NULL;';
  v_new:='v_client_key uuid;v_due date;v_is_new boolean:=p_document_id IS NULL;
  v_company_today date;';
  v_definition:=replace(v_definition,v_old,v_new);
  v_old:='IF p_receipt_date>current_date THEN RAISE EXCEPTION ''CUSTOMER_RECEIPT_DATE_FUTURE''; END IF;';
  v_new:='SELECT (clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO v_company_today FROM public.companies company
  WHERE company.id=v_company AND company.status=''ACTIVE'';
  IF v_company_today IS NULL THEN RAISE EXCEPTION ''ACTIVE_COMPANY_NOT_FOUND''; END IF;
  IF p_receipt_date>v_company_today THEN RAISE EXCEPTION ''CUSTOMER_RECEIPT_DATE_FUTURE''; END IF;';
  EXECUTE replace(v_definition,v_old,v_new);
END
$patch$;

REVOKE ALL ON FUNCTION
  public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)
  TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261110110000','backoffice_customer_receipt_company_date',
  'Customer Receipt future-date validation uses active Company timezone; allocation, Journal, permission, retry, Retail and Stock/FIFO behavior preserved');

COMMIT;
