-- G4 phase 49 forward fix: schema-qualify pgcrypto digest.
-- The canonical Supabase pgcrypto extension lives in schema `extensions` and
-- exposes digest(bytea,text), while the applied RPC called digest(text,text).

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260805090000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G4 phase 49 is incomplete';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260805100000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260805100000';
    END IF;
    IF to_regprocedure('extensions.digest(bytea,text)') IS NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: pgcrypto digest unavailable';
    END IF;
END
$migration_guard$;

CREATE OR REPLACE FUNCTION public.request_customer_balance_correction(
    p_customer_id UUID,p_store_id UUID,p_direction TEXT,p_amount NUMERIC,
    p_source_account_function TEXT,p_reason TEXT,p_evidence_url TEXT,
    p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
    v_company UUID:=public.private_active_company_id(); v_actor UUID:=auth.uid();
    v_customer public.customers%ROWTYPE; v_policy TEXT; v_direction TEXT:=upper(btrim(COALESCE(p_direction,'')));
    v_function TEXT:=upper(btrim(COALESCE(p_source_account_function,'')));
    v_hash TEXT; v_existing public.customer_balance_correction_requests%ROWTYPE;
    v_id UUID; v_no TEXT;
BEGIN
    IF v_company IS NULL OR v_actor IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
    IF v_direction NOT IN ('CREDIT','DEBIT') OR p_amount IS NULL OR p_amount<=0
       OR btrim(COALESCE(p_reason,''))='' OR v_function='' THEN
        RAISE EXCEPTION 'INVALID_CUSTOMER_BALANCE_CORRECTION';
    END IF;
    IF p_evidence_url IS NOT NULL AND p_evidence_url!~*'^https://' THEN
        RAISE EXCEPTION 'CUSTOMER_BALANCE_EVIDENCE_HTTPS_REQUIRED';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM public.stores store WHERE store.company_id=v_company AND store.id=p_store_id AND store.status='ACTIVE')
       OR NOT public.private_user_has_store_access(p_store_id) THEN
        RAISE EXCEPTION 'ACTIVE_STORE_NOT_FOUND';
    END IF;
    IF NOT (public.private_user_has_store_access(p_store_id)
        OR public.private_user_has_any_company_role(v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE']::TEXT[])) THEN
        RAISE EXCEPTION 'CUSTOMER_BALANCE_REQUEST_ACCESS_DENIED';
    END IF;
    SELECT * INTO v_customer FROM public.customers
    WHERE company_id=v_company AND id=p_customer_id;
    IF NOT FOUND OR v_customer.is_system_customer THEN
        RAISE EXCEPTION 'CUSTOMER_BALANCE_CUSTOMER_NOT_FOUND';
    END IF;
    SELECT lifecycle_state INTO v_policy
    FROM public.customer_balance_company_policies WHERE company_id=v_company;
    IF v_direction='CREDIT' AND (
        v_policy<>'ACTIVE' OR NOT v_customer.is_active OR NOT EXISTS(
            SELECT 1 FROM public.company_features feature
            WHERE feature.company_id=v_company
              AND feature.feature_code='customer_balance_enabled'
              AND feature.is_enabled
        )
    ) THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_CREDIT_DISABLED'; END IF;
    IF v_direction='DEBIT' AND v_policy NOT IN ('ACTIVE','WIND_DOWN') THEN
        RAISE EXCEPTION 'CUSTOMER_BALANCE_DEBIT_DISABLED';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM public.account_functions af WHERE af.function_key=v_function) THEN
        RAISE EXCEPTION 'CUSTOMER_BALANCE_SOURCE_FUNCTION_NOT_FOUND';
    END IF;
    v_hash:=encode(extensions.digest(
        convert_to(concat_ws('|',v_company,p_customer_id,p_store_id,
            v_direction,p_amount::NUMERIC(20,4),v_function,btrim(p_reason),
            COALESCE(p_evidence_url,'')),'UTF8'),
        'sha256'
    ),'hex');
    SELECT * INTO v_existing FROM public.customer_balance_correction_requests
    WHERE company_id=v_company AND idempotency_key=p_idempotency_key;
    IF FOUND THEN
        IF v_existing.payload_hash<>v_hash THEN RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT'; END IF;
        RETURN jsonb_build_object('correctionRequestId',v_existing.id,'requestNo',v_existing.request_no,'status',v_existing.status,'masterVersion',v_existing.master_version,'idempotentReplay',TRUE);
    END IF;
    v_no:='CB-COR-'||to_char(clock_timestamp(),'YYYYMMDD')||'-'||lpad(nextval('private.customer_balance_request_no_seq')::TEXT,10,'0');
    INSERT INTO public.customer_balance_correction_requests(
        company_id,customer_id,store_id,request_no,direction,amount,
        source_account_function,reason,evidence_url,idempotency_key,
        payload_hash,created_by
    ) VALUES(v_company,p_customer_id,p_store_id,v_no,v_direction,p_amount,
        v_function,btrim(p_reason),NULLIF(btrim(COALESCE(p_evidence_url,'')),''),
        p_idempotency_key,v_hash,v_actor) RETURNING id INTO v_id;
    INSERT INTO public.customer_balance_audit(
        company_id,customer_id,correction_request_id,action,actor_id,after_state
    ) SELECT v_company,p_customer_id,id,'REQUEST_CORRECTION',v_actor,to_jsonb(request)
      FROM public.customer_balance_correction_requests request WHERE id=v_id;
    RETURN jsonb_build_object('correctionRequestId',v_id,'requestNo',v_no,'status','SUBMITTED','masterVersion',1);
END;
$$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
    '20260805100000','g4_phase49_customer_balance_digest_fix',
    'Forward fix: Customer Balance request hash uses extensions.digest(bytea,text); no data or business-flow change'
);

COMMIT;
