-- KGS POS G1 phase 5C: canonical transaction read boundary and RPC guard.
-- Requirement: TEN-001, TEN-002
-- Dependency: 20260720230000_g1_phase5b_catalog_inventory_rls.sql
--
-- Browser roles receive scoped SELECT only. Session/Sales/Purchase writes must
-- use controlled workflows. The existing checkout implementation is preserved
-- behind an active-Company wrapper until G4 replaces its business contract.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260720230000'
       ) THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: G1 phase 5B not recorded';
    END IF;

    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260721090000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260721090000';
    END IF;
END
$migration_guard$;

DO $transaction_preflight$
DECLARE
    v_mismatch BIGINT;
BEGIN
    SELECT count(*) INTO v_mismatch
    FROM (
        SELECT id FROM public.cashier_sessions
        WHERE store_id IS NULL OR pos_id IS NULL

        UNION ALL

        SELECT id FROM public.sales_headers
        WHERE store_id IS NULL OR pos_id IS NULL

        UNION ALL

        SELECT id FROM public.purchases_headers
        WHERE store_id IS NULL

        UNION ALL

        SELECT d.id
        FROM public.sales_details d
        JOIN public.sales_headers h ON h.id = d.sales_id
        WHERE d.company_id IS DISTINCT FROM h.company_id

        UNION ALL

        SELECT p.id
        FROM public.sales_payments p
        JOIN public.sales_headers h ON h.id = p.sales_id
        WHERE p.company_id IS DISTINCT FROM h.company_id
           OR p.session_id IS DISTINCT FROM h.session_id

        UNION ALL

        SELECT d.id
        FROM public.purchases_details d
        JOIN public.purchases_headers h ON h.id = d.purchase_id
        WHERE d.company_id IS DISTINCT FROM h.company_id
    ) mismatches;

    IF v_mismatch > 0 THEN
        RAISE EXCEPTION 'G1_PHASE5C_TENANT_PRECONDITION_FAILED: % mismatch(es)',v_mismatch;
    END IF;

    IF to_regprocedure(
        'public.create_sales_transaction(text,uuid,uuid,boolean,timestamp with time zone,boolean,text,numeric,numeric,numeric,numeric,numeric,numeric,payment_status,uuid,jsonb,jsonb,jsonb)'
    ) IS NULL THEN
        RAISE EXCEPTION 'G1_PHASE5C_CHECKOUT_RPC_PRECONDITION_FAILED';
    END IF;
END
$transaction_preflight$;

ALTER TABLE public.cashier_sessions
    ALTER COLUMN store_id SET NOT NULL,
    ALTER COLUMN pos_id SET NOT NULL;
ALTER TABLE public.sales_headers
    ALTER COLUMN store_id SET NOT NULL,
    ALTER COLUMN pos_id SET NOT NULL;
ALTER TABLE public.purchases_headers
    ALTER COLUMN store_id SET NOT NULL;

-- Visibility helpers keep child tables aligned with their parent document.
CREATE OR REPLACE FUNCTION public.private_sales_document_visible(
    p_sales_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.sales_headers h
        WHERE h.id = p_sales_id
          AND public.private_request_company_matches(h.company_id)
          AND (
              h.created_by = auth.uid()
              OR public.private_user_has_any_company_role(
                  h.company_id,
                  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]
              )
              OR public.private_user_has_any_store_role(
                  h.store_id,
                  ARRAY['STORE_MANAGER']::TEXT[]
              )
          )
    );
$$;

CREATE OR REPLACE FUNCTION public.private_purchase_document_visible(
    p_purchase_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.purchases_headers h
        WHERE h.id = p_purchase_id
          AND public.private_request_company_matches(h.company_id)
          AND public.private_user_has_store_access(h.store_id)
    );
$$;

-- Preserve legacy checkout implementation but remove direct API execution.
ALTER FUNCTION public.create_sales_transaction(
    TEXT, UUID, UUID, BOOLEAN, TIMESTAMPTZ, BOOLEAN, TEXT,
    NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC,
    public.payment_status, UUID, JSONB, JSONB, JSONB
) RENAME TO private_create_sales_transaction_g1_legacy;

REVOKE ALL ON FUNCTION public.private_create_sales_transaction_g1_legacy(
    TEXT, UUID, UUID, BOOLEAN, TIMESTAMPTZ, BOOLEAN, TEXT,
    NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC,
    public.payment_status, UUID, JSONB, JSONB, JSONB
) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.create_sales_transaction(
    p_invoice_no TEXT,
    p_session_id UUID,
    p_customer_id UUID,
    p_is_tempo BOOLEAN,
    p_due_date TIMESTAMPTZ,
    p_sj_required BOOLEAN,
    p_sj_no TEXT,
    p_subtotal NUMERIC,
    p_item_discount NUMERIC,
    p_global_discount NUMERIC,
    p_grand_total NUMERIC,
    p_paid_amount NUMERIC,
    p_sisa_piutang NUMERIC,
    p_payment_status public.payment_status,
    p_created_by UUID,
    p_payload_snapshot JSONB,
    p_details JSONB,
    p_payments JSONB
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_company_id UUID;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'AUTHENTICATION_REQUIRED';
    END IF;

    IF p_created_by IS DISTINCT FROM auth.uid() THEN
        RAISE EXCEPTION 'INVALID_TRANSACTION_ACTOR';
    END IF;

    SELECT company_id INTO v_company_id
    FROM public.cashier_sessions
    WHERE id = p_session_id;

    IF v_company_id IS NULL THEN
        RAISE EXCEPTION 'SESSION_NOT_FOUND';
    END IF;

    IF NOT public.private_request_company_matches(v_company_id) THEN
        RAISE EXCEPTION 'ACTIVE_COMPANY_MISMATCH';
    END IF;

    RETURN public.private_create_sales_transaction_g1_legacy(
        p_invoice_no, p_session_id, p_customer_id, p_is_tempo, p_due_date,
        p_sj_required, p_sj_no, p_subtotal, p_item_discount,
        p_global_discount, p_grand_total, p_paid_amount, p_sisa_piutang,
        p_payment_status, p_created_by, p_payload_snapshot, p_details,
        p_payments
    );
END;
$$;

DO $drop_transaction_policies$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT tablename,policyname
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = ANY(ARRAY[
              'cashier_sessions','sales_headers','sales_details',
              'sales_payments','purchases_headers','purchases_details'
          ])
    LOOP
        EXECUTE format('DROP POLICY %I ON public.%I',r.policyname,r.tablename);
    END LOOP;
END
$drop_transaction_policies$;

ALTER TABLE public.cashier_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_headers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchases_headers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchases_details ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Cashier sessions readable by assigned operational roles"
ON public.cashier_sessions FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND (
        cashier_id = auth.uid()
        OR public.private_user_has_any_company_role(
            company_id,
            ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]
        )
        OR public.private_user_has_any_store_role(
            store_id,
            ARRAY['STORE_MANAGER']::TEXT[]
        )
    )
);

CREATE POLICY "Sales headers readable by document scope"
ON public.sales_headers FOR SELECT TO authenticated
USING (public.private_sales_document_visible(id));

CREATE POLICY "Sales details readable by parent Sale scope"
ON public.sales_details FOR SELECT TO authenticated
USING (public.private_sales_document_visible(sales_id));

CREATE POLICY "Sales payments readable by parent Sale scope"
ON public.sales_payments FOR SELECT TO authenticated
USING (public.private_sales_document_visible(sales_id));

CREATE POLICY "Purchase headers readable by Store scope"
ON public.purchases_headers FOR SELECT TO authenticated
USING (public.private_purchase_document_visible(id));

CREATE POLICY "Purchase details readable by parent Purchase scope"
ON public.purchases_details FOR SELECT TO authenticated
USING (public.private_purchase_document_visible(purchase_id));

-- Browser roles cannot directly create/update/delete transaction rows.
REVOKE ALL ON public.cashier_sessions, public.sales_headers,
    public.sales_details, public.sales_payments,
    public.purchases_headers, public.purchases_details
FROM PUBLIC, anon, authenticated;

GRANT SELECT ON public.cashier_sessions, public.sales_headers,
    public.sales_details, public.sales_payments,
    public.purchases_headers, public.purchases_details
TO authenticated;

GRANT ALL ON public.cashier_sessions, public.sales_headers,
    public.sales_details, public.sales_payments,
    public.purchases_headers, public.purchases_details
TO service_role;

DO $function_grants$
DECLARE
    v_signature TEXT;
BEGIN
    FOREACH v_signature IN ARRAY ARRAY[
        'public.private_sales_document_visible(uuid)',
        'public.private_purchase_document_visible(uuid)',
        'public.create_sales_transaction(text,uuid,uuid,boolean,timestamp with time zone,boolean,text,numeric,numeric,numeric,numeric,numeric,numeric,payment_status,uuid,jsonb,jsonb,jsonb)'
    ]
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon',v_signature);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role',v_signature);
    END LOOP;
END
$function_grants$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260721090000',
    'g1_phase5c_transaction_rls',
    'TEN-001/TEN-002 scoped transaction reads, no direct transaction mutation, and active-Company checkout wrapper'
);

NOTIFY pgrst, 'reload schema';

COMMIT;
