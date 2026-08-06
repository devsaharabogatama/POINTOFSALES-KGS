-- G4 phase 56: mandatory full Customer Balance usage in online POS checkout.
BEGIN;

DO $guard$
DECLARE v_definition TEXT; v_patched TEXT;
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260805130000'
    ) THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: phase52'; END IF;
    IF EXISTS(
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260805160000'
    ) THEN RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260805160000'; END IF;

    SELECT pg_get_functiondef(
        'private.post_pos_sale_online_core(uuid,bigint,uuid)'::regprocedure
    ) INTO v_definition;
    IF v_definition !~ 'CUSTOMER_BALANCE.*KETUL_OFFSET'
       OR v_definition !~ 'DEFERRED_PAYMENT_METHOD_NOT_ENABLED' THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Sale guard changed';
    END IF;
    v_patched:=regexp_replace(
        v_definition,
        'IF v_payment_method\.method_type IN \([[:space:]]*''CUSTOMER_BALANCE'',''KETUL_OFFSET''[[:space:]]*\) THEN[[:space:]]*RAISE EXCEPTION ''DEFERRED_PAYMENT_METHOD_NOT_ENABLED'';[[:space:]]*END IF;',
        'IF v_payment_method.method_type = ''KETUL_OFFSET'' THEN
                RAISE EXCEPTION ''DEFERRED_PAYMENT_METHOD_NOT_ENABLED'';
            END IF;'
    );
    IF v_patched=v_definition
       OR v_patched~'CUSTOMER_BALANCE'',''KETUL_OFFSET' THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Sale patch failed';
    END IF;
    EXECUTE v_patched;
END
$guard$;

ALTER TABLE public.sales_payments
    ADD COLUMN customer_balance_usage_amount NUMERIC(20,4)
        NOT NULL DEFAULT 0,
    ADD COLUMN customer_balance_usage_ledger_entry_id UUID,
    ADD CONSTRAINT sales_payments_customer_balance_usage_shape CHECK(
        (customer_balance_usage_amount=0
         AND customer_balance_usage_ledger_entry_id IS NULL)
        OR
        (customer_balance_usage_amount>0
         AND customer_balance_usage_ledger_entry_id IS NOT NULL
         AND payment_method_type_snapshot='CUSTOMER_BALANCE'
         AND amount=customer_balance_usage_amount
         AND COALESCE(change_amount,0)=0
         AND COALESCE(customer_surcharge_amount,0)=0)
    ),
    ADD CONSTRAINT fk_sales_payments_customer_balance_usage_ledger
        FOREIGN KEY(company_id,customer_balance_usage_ledger_entry_id)
        REFERENCES public.customer_balance_ledger_entries(company_id,id)
        ON DELETE RESTRICT;

CREATE UNIQUE INDEX uq_sales_payments_customer_balance_usage_ledger
    ON public.sales_payments(company_id,customer_balance_usage_ledger_entry_id)
    WHERE customer_balance_usage_ledger_entry_id IS NOT NULL;

ALTER TABLE public.customer_balance_ledger_entries
    DROP CONSTRAINT customer_balance_ledger_source_check,
    ADD CONSTRAINT customer_balance_ledger_source_check CHECK(
        source_type IN(
            'MANUAL_CORRECTION','SALE_OVERPAYMENT','SALE_PAYMENT'
        )
    );

ALTER TABLE public.customer_balance_audit
    DROP CONSTRAINT customer_balance_audit_action_check,
    ADD CONSTRAINT customer_balance_audit_action_check CHECK(
        action IN(
            'POLICY_PROVISION','POLICY_SYNC','REQUEST_CORRECTION',
            'APPROVE_CORRECTION','REJECT_CORRECTION','AUTO_DISABLE',
            'SALE_OVERPAYMENT_CREDIT','SALE_PAYMENT_DEBIT'
        )
    );

CREATE OR REPLACE FUNCTION private.trg_g4_customer_balance_source_integrity()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
    IF NEW.source_type='MANUAL_CORRECTION' THEN
        IF NOT EXISTS(SELECT 1 FROM public.customer_balance_correction_requests r
            WHERE r.company_id=NEW.company_id AND r.id=NEW.source_id) THEN
            RAISE EXCEPTION 'CUSTOMER_BALANCE_CORRECTION_SOURCE_NOT_FOUND';
        END IF;
    ELSIF NEW.source_type IN ('SALE_OVERPAYMENT','SALE_PAYMENT') THEN
        IF NOT EXISTS(SELECT 1 FROM public.sales_payments p
            WHERE p.company_id=NEW.company_id AND p.id=NEW.source_id
              AND NOT p.is_reversal) THEN
            RAISE EXCEPTION 'CUSTOMER_BALANCE_SALE_PAYMENT_SOURCE_NOT_FOUND';
        END IF;
    ELSE RAISE EXCEPTION 'CUSTOMER_BALANCE_SOURCE_NOT_SUPPORTED'; END IF;
    RETURN NEW;
END;
$$;

ALTER FUNCTION private.post_pos_sale_core(UUID,BIGINT,UUID)
    RENAME TO post_pos_sale_balance_credit_core;

CREATE FUNCTION private.post_pos_sale_core(
    p_sales_id UUID,p_master_version BIGINT,p_posting_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
    v_actor UUID:=auth.uid(); v_company UUID:=public.private_active_company_id();
    v_sale public.sales_headers%ROWTYPE; v_customer public.customers%ROWTYPE;
    v_payment public.sales_payments%ROWTYPE; v_result JSONB;
    v_usage_count BIGINT; v_usage_payload NUMERIC(20,4); v_usage NUMERIC(20,4);
    v_before NUMERIC(20,4); v_after NUMERIC(20,4); v_policy TEXT;
    v_category UUID; v_liability UUID; v_source UUID; v_event UUID; v_entry UUID;
    v_entry_no BIGINT; v_key UUID; v_hash TEXT; v_now TIMESTAMPTZ:=clock_timestamp();
BEGIN
    SELECT * INTO v_sale FROM public.sales_headers s
    WHERE s.company_id=v_company AND s.id=p_sales_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SALE_DRAFT_NOT_FOUND'; END IF;

    IF v_sale.document_status='DRAFT' THEN
        SELECT * INTO v_customer FROM public.customers c
        WHERE c.company_id=v_company AND c.id=v_sale.customer_id FOR UPDATE;
        IF FOUND AND NOT v_customer.is_system_customer THEN
            SELECT count(*),COALESCE(sum((leg->>'amount')::NUMERIC),0)
            INTO v_usage_count,v_usage_payload
            FROM jsonb_array_elements(COALESCE(
                v_sale.payload_snapshot->'payments','[]'::JSONB
            )) leg
            JOIN public.payment_methods method
              ON method.company_id=v_company
             AND method.id=(leg->>'paymentMethodId')::UUID
             AND method.method_type='CUSTOMER_BALANCE';

            v_usage:=v_customer.current_balance;
            IF v_usage>v_sale.grand_total_after_rounding THEN
                RAISE EXCEPTION 'CUSTOMER_BALANCE_EXCEEDS_SALE_TOTAL:%',
                    v_usage-v_sale.grand_total_after_rounding;
            END IF;
            IF v_usage>0 AND (v_usage_count<>1 OR v_usage_payload<>v_usage) THEN
                RAISE EXCEPTION 'FULL_CUSTOMER_BALANCE_USAGE_REQUIRED:%',v_usage;
            ELSIF v_usage=0 AND v_usage_count<>0 THEN
                RAISE EXCEPTION 'CUSTOMER_BALANCE_NOT_AVAILABLE';
            END IF;
            IF v_usage>0 THEN
                SELECT policy.lifecycle_state INTO v_policy
                FROM public.customer_balance_company_policies policy
                WHERE policy.company_id=v_company FOR UPDATE;
                IF v_policy NOT IN ('ACTIVE','WIND_DOWN') THEN
                    RAISE EXCEPTION 'CUSTOMER_BALANCE_DEBIT_DISABLED';
                END IF;
            END IF;
        ELSIF EXISTS(
            SELECT 1 FROM jsonb_array_elements(COALESCE(
                v_sale.payload_snapshot->'payments','[]'::JSONB
            )) leg JOIN public.payment_methods method
              ON method.company_id=v_company
             AND method.id=(leg->>'paymentMethodId')::UUID
             AND method.method_type='CUSTOMER_BALANCE'
        ) THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_CUSTOMER_NOT_FOUND'; END IF;
    END IF;

    v_result:=private.post_pos_sale_balance_credit_core(
        p_sales_id,p_master_version,p_posting_idempotency_key
    );
    IF v_result->>'documentStatus'<>'POSTED' THEN RETURN v_result; END IF;

    SELECT * INTO v_payment FROM public.sales_payments payment
    WHERE payment.company_id=v_company AND payment.sales_id=p_sales_id
      AND NOT payment.is_reversal
      AND payment.payment_method_type_snapshot='CUSTOMER_BALANCE';
    IF NOT FOUND THEN
        RETURN v_result||jsonb_build_object('customerBalanceUsageTotal',0);
    END IF;
    IF v_payment.customer_balance_usage_ledger_entry_id IS NOT NULL THEN
        RETURN v_result||jsonb_build_object(
            'customerBalanceUsageTotal',v_payment.customer_balance_usage_amount
        );
    END IF;
    SELECT count(*) INTO v_usage_count
    FROM public.sales_payments payment
    WHERE payment.company_id=v_company AND payment.sales_id=p_sales_id
      AND NOT payment.is_reversal
      AND payment.payment_method_type_snapshot='CUSTOMER_BALANCE';
    IF v_usage_count<>1 THEN
        RAISE EXCEPTION 'CUSTOMER_BALANCE_PAYMENT_LEG_INVALID';
    END IF;

    SELECT * INTO v_sale FROM public.sales_headers s
    WHERE s.company_id=v_company AND s.id=p_sales_id;
    SELECT * INTO v_customer FROM public.customers c
    WHERE c.company_id=v_company AND c.id=v_sale.customer_id FOR UPDATE;
    IF NOT FOUND OR v_customer.is_system_customer THEN
        RAISE EXCEPTION 'CUSTOMER_BALANCE_CUSTOMER_NOT_FOUND';
    END IF;
    v_usage:=v_payment.amount;
    v_before:=v_customer.current_balance;
    IF v_usage<=0 OR v_usage>v_before THEN
        RAISE EXCEPTION 'INSUFFICIENT_CUSTOMER_BALANCE';
    END IF;
    v_after:=v_before-v_usage;

    SELECT category.id INTO v_category FROM public.transaction_categories category
    WHERE category.company_id=v_company
      AND category.system_key='CUSTOMER_BALANCE_USAGE' AND category.is_active
    ORDER BY category.is_system_default DESC,category.id LIMIT 1;
    IF v_category IS NULL THEN
        RAISE EXCEPTION 'CUSTOMER_BALANCE_TRANSACTION_CATEGORY_NOT_FOUND';
    END IF;
    v_liability:=private.resolve_customer_balance_account(
        v_company,v_category,'CUSTOMER_BALANCE_LIABILITY',v_now
    );
    v_source:=private.resolve_customer_balance_account(
        v_company,v_category,'CUSTOMER_RECEIVABLE',v_now
    );
    v_key:=(substr(md5(v_company::TEXT||'|'||v_payment.id::TEXT||
            '|SALE_PAYMENT'),1,8)||'-'||
        substr(md5(v_company::TEXT||'|'||v_payment.id::TEXT||
            '|SALE_PAYMENT'),9,4)||'-'||
        substr(md5(v_company::TEXT||'|'||v_payment.id::TEXT||
            '|SALE_PAYMENT'),13,4)||'-'||
        substr(md5(v_company::TEXT||'|'||v_payment.id::TEXT||
            '|SALE_PAYMENT'),17,4)||'-'||
        substr(md5(v_company::TEXT||'|'||v_payment.id::TEXT||
            '|SALE_PAYMENT'),21,12))::UUID;
    v_hash:=encode(extensions.digest(convert_to(concat_ws('|',v_company,
        v_sale.id,v_payment.id,v_customer.id,v_usage,v_before,v_after),'UTF8'),
        'sha256'),'hex');

    INSERT INTO public.financial_events(
        event_code,event_type,source_table,source_id,root_sales_id,event_date,
        event_version,idempotency_key,payment_method,amounts,status,error_message,
        created_by,company_id,store_id,system_event_key,transaction_category_id
    ) VALUES(
        'CB-USE-'||replace(v_payment.id::TEXT,'-',''),
        'CUSTOMER_BALANCE_ADJUSTMENT'::public.event_type,'sales_payments',
        v_payment.id,v_sale.id,v_now,1,
        'SALE_PAYMENT|'||v_company||'|'||v_payment.id,
        v_payment.payment_method_name_snapshot,jsonb_build_object(
            'saleId',v_sale.id,'paymentId',v_payment.id,
            'customerId',v_customer.id,'direction','DEBIT','amount',v_usage,
            'balanceBefore',v_before,'balanceAfter',v_after,
            'liabilityAccountId',v_liability,'sourceAccountId',v_source,
            'financePostingState','HOLD_UNTIL_G6'
        ),'HOLD'::public.event_status,'CANONICAL_FINANCE_POSTING_NOT_ENABLED',
        v_actor,v_company,v_sale.store_id,'CUSTOMER_BALANCE_USAGE',v_category
    ) RETURNING id INTO v_event;

    v_entry_no:=nextval('private.customer_balance_request_no_seq');
    INSERT INTO public.customer_balance_ledger_entries(
        company_id,customer_id,store_id,entry_no,direction,amount,source_type,
        source_id,source_reference,reason,balance_before,balance_after,
        transaction_category_id,liability_account_id,source_account_id,
        source_account_function,financial_event_id,idempotency_key,payload_hash,
        created_by
    ) VALUES(
        v_company,v_customer.id,v_sale.store_id,v_entry_no,'DEBIT',v_usage,
        'SALE_PAYMENT',v_payment.id,COALESCE(v_sale.invoice_no,v_payment.payment_no),
        'Saldo Customer digunakan untuk pembayaran Sale',v_before,v_after,
        v_category,v_liability,v_source,'CUSTOMER_RECEIVABLE',v_event,v_key,
        v_hash,v_actor
    ) RETURNING id INTO v_entry;

    UPDATE public.customers SET current_balance=v_after,updated_by=v_actor
    WHERE company_id=v_company AND id=v_customer.id;
    UPDATE public.sales_payments SET
        customer_balance_usage_amount=v_usage,
        customer_balance_usage_ledger_entry_id=v_entry,
        balance_before=v_before,balance_after=v_after
    WHERE company_id=v_company AND id=v_payment.id;
    INSERT INTO public.customer_balance_audit(
        company_id,customer_id,action,actor_id,before_state,after_state
    ) VALUES(v_company,v_customer.id,'SALE_PAYMENT_DEBIT',v_actor,
        jsonb_build_object('balance',v_before,'paymentId',v_payment.id),
        jsonb_build_object('balance',v_after,'paymentId',v_payment.id,
            'ledgerEntryId',v_entry,'amount',v_usage));

    IF v_after=0 AND v_policy='WIND_DOWN' THEN
        UPDATE public.customer_balance_company_policies SET
            lifecycle_state='DISABLED',master_version=master_version+1,
            updated_by=v_actor,updated_at=v_now
        WHERE company_id=v_company AND lifecycle_state='WIND_DOWN';
        UPDATE public.payment_methods SET is_active=FALSE,updated_by=v_actor
        WHERE company_id=v_company AND method_type='CUSTOMER_BALANCE' AND is_active;
    END IF;
    RETURN v_result||jsonb_build_object('customerBalanceUsageTotal',v_usage);
END;
$$;

ALTER FUNCTION public.post_pos_sale(UUID,BIGINT,UUID) SET SCHEMA private;
ALTER FUNCTION private.post_pos_sale(UUID,BIGINT,UUID)
    RENAME TO post_pos_sale_phase52_public_core;

CREATE FUNCTION public.post_pos_sale(
    p_sales_id UUID,p_master_version BIGINT,p_posting_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id(); v_result JSONB;
    v_receipt JSONB;
BEGIN
    v_result:=private.post_pos_sale_phase52_public_core(
        p_sales_id,p_master_version,p_posting_idempotency_key
    );
    IF v_result->>'documentStatus'='POSTED' THEN
        SELECT jsonb_set(sale.receipt_snapshot,'{payments}',COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'clientPaymentKey',payment.client_payment_key,
                'paymentMethodName',payment.payment_method_name_snapshot,
                'paymentMethodType',payment.payment_method_type_snapshot,
                'amount',payment.amount,'configuredFee',payment.configured_fee_amount,
                'customerSurcharge',payment.customer_surcharge_amount,
                'tenderedAmount',payment.tendered_amount,
                'changeAmount',payment.change_amount,
                'overpaymentDisposition',payment.overpayment_disposition,
                'customerBalanceCreditAmount',payment.customer_balance_credit_amount,
                'customerBalanceLedgerEntryId',payment.customer_balance_ledger_entry_id,
                'customerBalanceUsageAmount',payment.customer_balance_usage_amount,
                'customerBalanceUsageLedgerEntryId',
                    payment.customer_balance_usage_ledger_entry_id,
                'proofUrl',payment.proof_url
            ) ORDER BY payment.payment_no)
            FROM public.sales_payments payment
            WHERE payment.company_id=v_company AND payment.sales_id=p_sales_id
              AND NOT payment.is_reversal
        ),'[]'::JSONB),TRUE) INTO v_receipt
        FROM public.sales_headers sale
        WHERE sale.company_id=v_company AND sale.id=p_sales_id;
        UPDATE public.sales_headers SET receipt_snapshot=v_receipt
        WHERE company_id=v_company AND id=p_sales_id;
        v_result:=v_result||jsonb_build_object('receipt',v_receipt);
    END IF;
    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION
    private.post_pos_sale_balance_credit_core(UUID,BIGINT,UUID),
    private.post_pos_sale_phase52_public_core(UUID,BIGINT,UUID),
    private.post_pos_sale_core(UUID,BIGINT,UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.post_pos_sale_balance_credit_core(UUID,BIGINT,UUID),
    private.post_pos_sale_phase52_public_core(UUID,BIGINT,UUID),
    private.post_pos_sale_core(UUID,BIGINT,UUID)
TO service_role;
REVOKE ALL ON FUNCTION public.post_pos_sale(UUID,BIGINT,UUID)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.post_pos_sale(UUID,BIGINT,UUID)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260805160000','g4_phase56_customer_balance_tender',
    'POS-006 mandatory full online Customer Balance usage, ledger debit, Payment/receipt snapshot, idempotency and WIND_DOWN close');
COMMIT;
