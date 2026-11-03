-- Forward fix: make automatic Customer code allocation collision-safe.

BEGIN;

DO $migration_guard$
DECLARE
  v_missing text[];
  v_save_definition text;
  v_quick_definition text;
BEGIN
  SELECT array_agg(required.version ORDER BY required.version)
  INTO v_missing
  FROM (VALUES
    ('20260722010000'),('20260722040000'),('20260730040000'),
    ('20260812220000'),('20260819150000'),('20261008130000'),
    ('20261102160000')
  ) required(version)
  WHERE NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations migration
    WHERE migration.version=required.version);
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: missing %',v_missing;
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations migration
    WHERE migration.version='20261102170000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20261102170000';
  END IF;
  IF to_regprocedure('private.allocate_customer_code(uuid)') IS NOT NULL
     OR to_regprocedure('private.trg_customer_code_sequence_floor()') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: allocator object already exists';
  END IF;
  IF EXISTS(SELECT 1 FROM pg_trigger trigger_state
    WHERE trigger_state.tgrelid='public.customers'::regclass
      AND trigger_state.tgname='trg_customers_code_sequence_floor'
      AND NOT trigger_state.tgisinternal) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: allocator trigger already exists';
  END IF;
  IF EXISTS(SELECT 1 FROM public.master_import_jobs job
    WHERE job.import_type='CUSTOMER'
      AND job.status NOT IN('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Customer import';
  END IF;
  SELECT pg_get_functiondef(to_regprocedure(
    'public.save_customer(uuid,bigint,text,text,uuid,text,text,text,text,numeric,integer,text,boolean)'))
  INTO v_save_definition;
  SELECT pg_get_functiondef(to_regprocedure(
    'public.quick_create_pos_customer(text,text,text,text,text)'))
  INTO v_quick_definition;
  IF v_save_definition IS NULL OR v_quick_definition IS NULL
     OR strpos(v_save_definition,'INSERT INTO private.customer_code_sequences(company_id,next_value)')=0
     OR strpos(v_quick_definition,'INSERT INTO private.customer_code_sequences(company_id,next_value)')=0
     OR strpos(v_save_definition,'private.allocate_customer_code')>0
     OR strpos(v_quick_definition,'private.allocate_customer_code')>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Customer writer anchor changed';
  END IF;
END
$migration_guard$;

CREATE FUNCTION private.allocate_customer_code(p_company_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_existing_max bigint:=0;
  v_stored_next bigint:=1;
  v_candidate bigint;
  v_code text;
BEGIN
  IF p_company_id IS NULL OR NOT EXISTS(
    SELECT 1 FROM public.companies company WHERE company.id=p_company_id
  ) THEN
    RAISE EXCEPTION 'COMPANY_NOT_FOUND';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    'CUSTOMER_CODE:'||p_company_id::text,0));

  SELECT COALESCE(max((substring(upper(btrim(customer.code))
      FROM '^CUST-([0-9]{1,18})$'))::bigint),0)
  INTO v_existing_max
  FROM public.customers customer
  WHERE customer.company_id=p_company_id
    AND upper(btrim(customer.code)) ~ '^CUST-[0-9]{1,18}$';

  SELECT COALESCE(sequence.next_value,1)
  INTO v_stored_next
  FROM private.customer_code_sequences sequence
  WHERE sequence.company_id=p_company_id;
  IF NOT FOUND THEN v_stored_next:=1; END IF;

  v_candidate:=greatest(v_stored_next,v_existing_max+1,1);
  LOOP
    v_code:='CUST-'||CASE WHEN v_candidate<1000000
      THEN lpad(v_candidate::text,6,'0') ELSE v_candidate::text END;
    EXIT WHEN NOT EXISTS(
      SELECT 1 FROM public.customers customer
      WHERE customer.company_id=p_company_id
        AND upper(regexp_replace(btrim(customer.code),'\s+',' ','g'))=upper(v_code)
    );
    v_candidate:=v_candidate+1;
  END LOOP;

  INSERT INTO private.customer_code_sequences(company_id,next_value)
  VALUES(p_company_id,v_candidate+1)
  ON CONFLICT(company_id) DO UPDATE
  SET next_value=greatest(private.customer_code_sequences.next_value,EXCLUDED.next_value);
  RETURN v_code;
END
$$;

REVOKE ALL ON FUNCTION private.allocate_customer_code(uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.trg_customer_code_sequence_floor()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_suffix bigint;
BEGIN
  IF upper(btrim(NEW.code)) !~ '^CUST-[0-9]{1,18}$' THEN RETURN NEW; END IF;
  v_suffix:=(substring(upper(btrim(NEW.code)) FROM '^CUST-([0-9]{1,18})$'))::bigint;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'CUSTOMER_CODE:'||NEW.company_id::text,0));
  INSERT INTO private.customer_code_sequences(company_id,next_value)
  VALUES(NEW.company_id,v_suffix+1)
  ON CONFLICT(company_id) DO UPDATE
  SET next_value=greatest(private.customer_code_sequences.next_value,EXCLUDED.next_value);
  RETURN NEW;
END
$$;

REVOKE ALL ON FUNCTION private.trg_customer_code_sequence_floor() FROM PUBLIC,anon,authenticated;

CREATE TRIGGER trg_customers_code_sequence_floor
BEFORE INSERT OR UPDATE OF code ON public.customers
FOR EACH ROW EXECUTE FUNCTION private.trg_customer_code_sequence_floor();

-- Reconcile every Company monotonically; no Customer row is rewritten.
INSERT INTO private.customer_code_sequences(company_id,next_value)
SELECT company.id,COALESCE(floor.max_canonical,0)+1
FROM public.companies company
LEFT JOIN LATERAL (
  SELECT max((substring(upper(btrim(customer.code))
    FROM '^CUST-([0-9]{1,18})$'))::bigint) AS max_canonical
  FROM public.customers customer
  WHERE customer.company_id=company.id
    AND upper(btrim(customer.code)) ~ '^CUST-[0-9]{1,18}$'
) floor ON TRUE
ON CONFLICT(company_id) DO UPDATE
SET next_value=greatest(private.customer_code_sequences.next_value,EXCLUDED.next_value);

DO $patch_customer_writers$
DECLARE
  v_oid oid;
  v_definition text;
  v_old text;
  v_new text;
BEGIN
  v_oid:=to_regprocedure(
    'public.save_customer(uuid,bigint,text,text,uuid,text,text,text,text,numeric,integer,text,boolean)');
  SELECT pg_get_functiondef(v_oid) INTO v_definition;
  v_old:=$anchor$
            INSERT INTO private.customer_code_sequences(company_id,next_value)
            VALUES (v_company_id,2)
            ON CONFLICT (company_id) DO UPDATE
            SET next_value = private.customer_code_sequences.next_value + 1
            RETURNING next_value - 1 INTO v_sequence;
            v_code := 'CUST-' || lpad(v_sequence::TEXT,6,'0');$anchor$;
  v_new:=$replacement$
            v_code := private.allocate_customer_code(v_company_id);$replacement$;
  IF (length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: save_customer allocator anchor mismatch';
  END IF;
  EXECUTE replace(v_definition,v_old,v_new);

  v_oid:=to_regprocedure('public.quick_create_pos_customer(text,text,text,text,text)');
  SELECT pg_get_functiondef(v_oid) INTO v_definition;
  v_old:=$anchor$
    INSERT INTO private.customer_code_sequences(company_id,next_value)
    VALUES (v_company,2)
    ON CONFLICT (company_id) DO UPDATE
    SET next_value = private.customer_code_sequences.next_value + 1
    RETURNING next_value - 1 INTO v_sequence;
    v_code := 'CUST-' || lpad(v_sequence::TEXT,6,'0');$anchor$;
  v_new:=$replacement$
    v_code := private.allocate_customer_code(v_company);$replacement$;
  IF (length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: quick-create allocator anchor mismatch';
  END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$patch_customer_writers$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261102170000','customer_code_allocator_collision_forward_fix',
  'Shared per-Company collision-safe Customer code allocator; monotonic counter reconciliation; POS and Backoffice automatic writers only');

NOTIFY pgrst,'reload schema';
COMMIT;
