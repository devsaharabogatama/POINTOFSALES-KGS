-- SLD-R2: canonical delivery fee and Finance catalog foundation.
--
-- Compatibility:
-- - existing Sales, Invoice snapshots, and Financial Events remain immutable;
-- - payloads without deliveryFeeAmount remain PICKUP/zero-fee compatible;
-- - delivery fee is added after Product rounding and is never taxed implicitly;
-- - actual courier cost remains an independent Expense.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260811130000'
    ) OR NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260810200000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: SLD-2 and G6 phase 4 required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260811140000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260811140000';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.pos_offline_sale_submissions
        WHERE status IN ('QUEUED','SYNCING','NEEDS_CONFIRMATION')
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: nonterminal Offline Sale exists';
    END IF;
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='sales_headers'
          AND column_name IN (
              'delivery_fee_amount','delivery_fee_invoice_display_mode'
          )
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: delivery fee columns already exist';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.account_functions
        WHERE function_key='DELIVERY_FEE_REVENUE'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: delivery fee function exists';
    END IF;
END
$migration_guard$;

ALTER TABLE public.sales_headers
    ADD COLUMN delivery_fee_amount NUMERIC(20,4) NOT NULL DEFAULT 0,
    ADD COLUMN delivery_fee_invoice_display_mode TEXT NOT NULL
        DEFAULT 'SHOW_SEPARATE',
    ADD CONSTRAINT sales_headers_delivery_fee_nonnegative
        CHECK(delivery_fee_amount>=0),
    ADD CONSTRAINT sales_headers_delivery_fee_display_mode_check
        CHECK(delivery_fee_invoice_display_mode IN (
            'SHOW_SEPARATE','HIDE_BREAKDOWN'
        )),
    ADD CONSTRAINT sales_headers_delivery_fee_fulfillment_check
        CHECK(delivery_fee_amount=0 OR fulfillment_mode='DELIVERY');

COMMENT ON COLUMN public.sales_headers.delivery_fee_amount IS
    'Customer-billed delivery fee; server authoritative and included in grand total.';
COMMENT ON COLUMN public.sales_headers.delivery_fee_invoice_display_mode IS
    'Invoice presentation only; never changes total or Finance classification.';

-- Preserve the active Draft lock wrapper as an internal core. All existing
-- callers (Pricelist and Offline) continue resolving the public wrapper below.
ALTER FUNCTION public.save_pos_sale_draft(JSONB) SET SCHEMA private;
ALTER FUNCTION private.save_pos_sale_draft(JSONB)
    RENAME TO save_pos_sale_draft_sld_r2_core;

CREATE FUNCTION public.save_pos_sale_draft(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_company UUID:=public.private_active_company_id();
    v_fee NUMERIC(20,4):=0;
    v_mode TEXT:='SHOW_SEPARATE';
    v_fulfillment TEXT:='PICKUP';
    v_payload JSONB;
    v_result JSONB;
    v_sale_id UUID;
    v_sale public.sales_headers%ROWTYPE;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'SALE_PAYLOAD_OBJECT_REQUIRED';
    END IF;
    BEGIN
        v_fee:=round(COALESCE(NULLIF(
            btrim(p_payload->>'deliveryFeeAmount'),''
        )::NUMERIC,0),4);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'INVALID_DELIVERY_FEE_AMOUNT';
    END;
    IF v_fee<0 OR v_fee>999999999999999.9999 THEN
        RAISE EXCEPTION 'INVALID_DELIVERY_FEE_AMOUNT';
    END IF;
    v_mode:=upper(btrim(COALESCE(
        NULLIF(p_payload->>'deliveryFeeInvoiceDisplayMode',''),
        'SHOW_SEPARATE'
    )));
    IF v_mode NOT IN ('SHOW_SEPARATE','HIDE_BREAKDOWN') THEN
        RAISE EXCEPTION 'INVALID_DELIVERY_FEE_INVOICE_DISPLAY_MODE';
    END IF;
    v_fulfillment:=upper(btrim(COALESCE(
        NULLIF(p_payload->>'fulfillmentMode',''),'PICKUP'
    )));
    IF v_fulfillment NOT IN ('PICKUP','DELIVERY') THEN
        RAISE EXCEPTION 'INVALID_FULFILLMENT_MODE';
    END IF;
    IF v_fulfillment='PICKUP' AND v_fee<>0 THEN
        RAISE EXCEPTION 'PICKUP_DELIVERY_FEE_NOT_ALLOWED';
    END IF;

    v_payload:=p_payload||jsonb_build_object(
        'fulfillmentMode',v_fulfillment,
        'deliveryFeeAmount',v_fee,
        'deliveryFeeInvoiceDisplayMode',v_mode
    );
    v_result:=private.save_pos_sale_draft_sld_r2_core(v_payload);
    v_sale_id:=(v_result->>'salesId')::UUID;

    SELECT sale.* INTO STRICT v_sale
    FROM public.sales_headers sale
    WHERE sale.company_id=v_company AND sale.id=v_sale_id
    FOR UPDATE;
    IF v_sale.document_status<>'DRAFT' THEN
        RETURN v_result;
    END IF;

    -- Repricing core always starts from Product lines, so this addition is
    -- retry-safe and cannot compound on repeated Draft saves.
    UPDATE public.sales_headers SET
        delivery_fee_amount=v_fee,
        delivery_fee_invoice_display_mode=v_mode,
        grand_total=grand_total+v_fee,
        grand_total_before_rounding=grand_total_before_rounding+v_fee,
        grand_total_after_rounding=grand_total_after_rounding+v_fee,
        payload_snapshot=payload_snapshot||jsonb_build_object(
            'deliveryFeeAmount',v_fee,
            'deliveryFeeInvoiceDisplayMode',v_mode
        )
    WHERE company_id=v_company AND id=v_sale_id
      AND document_status='DRAFT';

    RETURN v_result||jsonb_build_object(
        'deliveryFeeAmount',v_fee,
        'deliveryFeeInvoiceDisplayMode',v_mode,
        'grandTotalBeforeRounding',
            (v_result->>'grandTotalBeforeRounding')::NUMERIC+v_fee,
        'grandTotalAfterRounding',
            (v_result->>'grandTotalAfterRounding')::NUMERIC+v_fee
    );
END;
$$;

-- Enrich the receipt in the same POST update. This does not create a second
-- mutation and therefore preserves optimistic version/idempotency behavior.
CREATE FUNCTION private.trg_sld_r2_capture_posted_delivery_fee()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
BEGIN
    IF OLD.document_status='POSTED' AND (
        NEW.delivery_fee_amount IS DISTINCT FROM OLD.delivery_fee_amount
        OR NEW.delivery_fee_invoice_display_mode IS DISTINCT FROM
            OLD.delivery_fee_invoice_display_mode
    ) THEN
        RAISE EXCEPTION 'POSTED_DELIVERY_FEE_IMMUTABLE';
    END IF;
    IF NEW.document_status='POSTED' AND OLD.document_status<>'POSTED' THEN
        NEW.receipt_snapshot:=COALESCE(NEW.receipt_snapshot,'{}'::JSONB)
            ||jsonb_build_object(
                'deliveryFeeAmount',NEW.delivery_fee_amount,
                'deliveryFeeInvoiceDisplayMode',
                    NEW.delivery_fee_invoice_display_mode
            );
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER sld_r2_capture_posted_delivery_fee
BEFORE UPDATE ON public.sales_headers
FOR EACH ROW EXECUTE FUNCTION private.trg_sld_r2_capture_posted_delivery_fee();

-- Keep the complete SLD-2 snapshot builder as the core and enrich only the
-- immutable totals object for newly posted Sales.
ALTER FUNCTION private.build_sales_invoice_snapshot(UUID,UUID,TEXT)
    RENAME TO build_sales_invoice_snapshot_sld_r2_core;

CREATE FUNCTION private.build_sales_invoice_snapshot(
    p_company_id UUID,p_sales_id UUID,p_provenance TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_snapshot JSONB;
    v_fee NUMERIC(20,4);
    v_mode TEXT;
BEGIN
    v_snapshot:=private.build_sales_invoice_snapshot_sld_r2_core(
        p_company_id,p_sales_id,p_provenance
    );
    SELECT sale.delivery_fee_amount,sale.delivery_fee_invoice_display_mode
    INTO v_fee,v_mode
    FROM public.sales_headers sale
    WHERE sale.company_id=p_company_id AND sale.id=p_sales_id;
    IF v_snapshot IS NULL THEN RETURN NULL; END IF;
    RETURN jsonb_set(
        v_snapshot,'{totals}',
        COALESCE(v_snapshot->'totals','{}'::JSONB)||jsonb_build_object(
            'deliveryFee',COALESCE(v_fee,0),
            'deliveryFeeInvoiceDisplayMode',COALESCE(
                v_mode,'SHOW_SEPARATE'
            )
        ),TRUE
    );
END;
$$;

-- SALE_POSTED is created before the Sale row changes to POSTED. Resolve the
-- fee from the locked Draft and separate Product net sales from delivery
-- revenue. Existing immutable Events are intentionally untouched.
CREATE FUNCTION private.trg_sld_r2_sale_event_delivery_fee()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_fee NUMERIC(20,4):=0;
BEGIN
    IF NEW.system_event_key='SALE_POSTED'
       AND NEW.source_table='sales_headers' THEN
        SELECT COALESCE(sale.delivery_fee_amount,0) INTO v_fee
        FROM public.sales_headers sale
        WHERE sale.company_id=NEW.company_id AND sale.id=NEW.source_id;
        IF NOT FOUND THEN RAISE EXCEPTION 'SALE_EVENT_SOURCE_NOT_FOUND'; END IF;
        NEW.amounts:=COALESCE(NEW.amounts,'{}'::JSONB)||jsonb_build_object(
            'deliveryFee',v_fee,
            'netSalesInclusiveTax',round(
                COALESCE((NEW.amounts->>'netSalesInclusiveTax')::NUMERIC,0)
                -v_fee,4
            )
        );
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER sld_r2_sale_event_delivery_fee
BEFORE INSERT ON public.financial_events
FOR EACH ROW EXECUTE FUNCTION private.trg_sld_r2_sale_event_delivery_fee();

INSERT INTO public.account_functions(
    function_key,function_name,compatible_account_types,
    default_normal_balance,allow_reconciliation
) VALUES(
    'DELIVERY_FEE_REVENUE','Pendapatan Ongkir',
    ARRAY['REVENUE','OTHER_INCOME']::TEXT[],'CREDIT',FALSE
);

UPDATE public.system_events SET
    conditional_account_functions=array_append(
        conditional_account_functions,'DELIVERY_FEE_REVENUE'
    ),
    updated_at=clock_timestamp()
WHERE system_key='SALE_POSTED'
  AND NOT ('DELIVERY_FEE_REVENUE'=ANY(
      required_account_functions||conditional_account_functions
      ||optional_account_functions
  ));

CREATE FUNCTION private.provision_sld_r2_delivery_revenue(
    p_company_id UUID,p_actor_id UUID DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_actor UUID:=p_actor_id;
    v_account_id UUID;
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM public.companies company
        WHERE company.id=p_company_id AND company.status='ACTIVE'
    ) THEN RETURN; END IF;
    IF v_actor IS NULL THEN
        SELECT profile.id INTO v_actor
        FROM public.profiles profile
        JOIN auth.users auth_user ON auth_user.id=profile.id
        WHERE profile.role::TEXT='super_admin'
        ORDER BY profile.id LIMIT 1;
    END IF;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    SELECT account.id INTO v_account_id
    FROM public.chart_of_accounts account
    WHERE account.company_id=p_company_id
      AND account.system_function_key='DELIVERY_FEE_REVENUE'
      AND account.is_system_account;
    IF v_account_id IS NULL THEN
        INSERT INTO public.chart_of_accounts(
            company_id,account_code,account_name,account_type,normal_balance,
            system_function_key,is_system_account,is_postable,
            allow_manual_posting,allow_reconciliation,created_by,updated_by
        ) VALUES(
            p_company_id,
            'SYS-DFR-'||substr(replace(p_company_id::TEXT,'-',''),1,8),
            'Pendapatan Ongkir Sistem '
                ||substr(replace(p_company_id::TEXT,'-',''),1,8),
            'REVENUE','CREDIT',
            'DELIVERY_FEE_REVENUE',TRUE,TRUE,FALSE,FALSE,v_actor,v_actor
        ) RETURNING id INTO v_account_id;
    END IF;

    IF NOT EXISTS(
        SELECT 1 FROM public.company_account_function_fallbacks fallback
        WHERE fallback.company_id=p_company_id
          AND fallback.account_function_key='DELIVERY_FEE_REVENUE'
          AND fallback.status='ACTIVE'
    ) THEN
        INSERT INTO public.company_account_function_fallbacks(
            company_id,account_function_key,account_id,effective_from,
            fallback_version,status,approved_by,approved_at,
            created_by,updated_by
        ) VALUES(
            p_company_id,'DELIVERY_FEE_REVENUE',v_account_id,'2000-01-01',
            COALESCE((SELECT max(fallback.fallback_version)+1
                FROM public.company_account_function_fallbacks fallback
                WHERE fallback.company_id=p_company_id
                  AND fallback.account_function_key=
                    'DELIVERY_FEE_REVENUE'),1),
            'ACTIVE',v_actor,clock_timestamp(),v_actor,v_actor
        );
    END IF;
END
$$;

CREATE FUNCTION private.trg_sld_r2_provision_delivery_revenue()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
BEGIN
    IF NEW.status='ACTIVE' AND (
        TG_OP='INSERT' OR OLD.status IS DISTINCT FROM NEW.status
    ) THEN
        PERFORM private.provision_sld_r2_delivery_revenue(NEW.id,auth.uid());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER sld_r2_provision_delivery_revenue
AFTER INSERT OR UPDATE OF status ON public.companies
FOR EACH ROW EXECUTE FUNCTION private.trg_sld_r2_provision_delivery_revenue();

DO $provision_delivery_revenue$
DECLARE v_company RECORD;
BEGIN
    FOR v_company IN
        SELECT company.id FROM public.companies company
        WHERE company.status='ACTIVE' ORDER BY company.id
    LOOP
        PERFORM private.provision_sld_r2_delivery_revenue(v_company.id,NULL);
    END LOOP;
END
$provision_delivery_revenue$;

REVOKE ALL ON FUNCTION
    private.save_pos_sale_draft_sld_r2_core(JSONB),
    private.build_sales_invoice_snapshot_sld_r2_core(UUID,UUID,TEXT),
    private.build_sales_invoice_snapshot(UUID,UUID,TEXT),
    private.provision_sld_r2_delivery_revenue(UUID,UUID),
    private.trg_sld_r2_provision_delivery_revenue(),
    private.trg_sld_r2_capture_posted_delivery_fee(),
    private.trg_sld_r2_sale_event_delivery_fee()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.save_pos_sale_draft_sld_r2_core(JSONB),
    private.build_sales_invoice_snapshot_sld_r2_core(UUID,UUID,TEXT),
    private.build_sales_invoice_snapshot(UUID,UUID,TEXT),
    private.provision_sld_r2_delivery_revenue(UUID,UUID),
    private.trg_sld_r2_provision_delivery_revenue(),
    private.trg_sld_r2_capture_posted_delivery_fee(),
    private.trg_sld_r2_sale_event_delivery_fee()
TO service_role;

REVOKE ALL ON FUNCTION public.save_pos_sale_draft(JSONB)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.save_pos_sale_draft(JSONB)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
    '20260811140000','sld_r2_delivery_fee_finance_foundation',
    'Server-authoritative delivery fee totals, immutable receipt/invoice/event snapshots, and explicit Company delivery-revenue account mapping'
);

COMMIT;
