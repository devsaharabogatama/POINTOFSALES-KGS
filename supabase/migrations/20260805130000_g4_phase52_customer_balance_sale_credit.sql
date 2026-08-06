-- KGS POS G4 phase 52: atomic Sale overpayment -> Customer Balance credit.
-- Requirement: POS-006
-- Dependency: G4 phase 49 Customer Balance foundation + digest fix.
--
-- This phase opens credit from a newly posted ONLINE Sale only. Customer
-- Balance as checkout tender, refund-to-balance, Offline credit, and Ketul
-- remain closed. Historical Cash change remains treated as returned change.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version='20260805090000'
       )
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version='20260805100000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G4 phase 49 chain is incomplete';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260805130000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260805130000';
    END IF;
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='sales_payments'
          AND column_name IN (
              'overpayment_disposition','customer_balance_credit_amount',
              'customer_balance_ledger_entry_id'
          )
    ) THEN
        RAISE EXCEPTION 'G4_PHASE52_PAYMENT_SNAPSHOT_ALREADY_EXISTS';
    END IF;
    IF to_regprocedure(
        'private.post_pos_sale_core(uuid,bigint,uuid)'
    ) IS NULL OR to_regprocedure(
        'public.post_pos_sale(uuid,bigint,uuid)'
    ) IS NULL THEN
        RAISE EXCEPTION 'G4_PHASE52_CANONICAL_SALE_RUNTIME_MISSING';
    END IF;
    -- The approved preflight reported zero historical non-Cash overpayment.
    -- Such rows are ambiguous and must never be silently credited/backfilled.
    IF EXISTS (
        SELECT 1 FROM public.sales_payments payment
        WHERE NOT payment.is_reversal
          AND payment.payment_method_type_snapshot IS DISTINCT FROM 'CASH'
          AND payment.change_amount>0
    ) THEN
        RAISE EXCEPTION
            'G4_PHASE52_STATE_CHANGED: non-Cash overpayment requires explicit review';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.customer_balance_ledger_entries entry
        WHERE entry.source_type<>'MANUAL_CORRECTION'
    ) THEN
        RAISE EXCEPTION
            'G4_PHASE52_STATE_CHANGED: unexpected Customer Balance source';
    END IF;
END
$migration_guard$;

ALTER TABLE public.sales_payments
    ADD COLUMN overpayment_disposition TEXT,
    ADD COLUMN customer_balance_credit_amount NUMERIC(20,4)
        NOT NULL DEFAULT 0,
    ADD COLUMN customer_balance_ledger_entry_id UUID,
    ADD CONSTRAINT sales_payments_overpayment_disposition_check CHECK (
        overpayment_disposition IS NULL
        OR overpayment_disposition IN ('NONE','RETURNED','CUSTOMER_BALANCE')
    ),
    ADD CONSTRAINT sales_payments_overpayment_credit_shape_check CHECK (
        (
            overpayment_disposition IS NULL
            AND customer_balance_credit_amount=0
            AND customer_balance_ledger_entry_id IS NULL
        )
        OR (
            overpayment_disposition='NONE'
            AND change_amount=0
            AND customer_balance_credit_amount=0
            AND customer_balance_ledger_entry_id IS NULL
        )
        OR (
            overpayment_disposition='RETURNED'
            AND customer_balance_credit_amount=0
            AND customer_balance_ledger_entry_id IS NULL
        )
        OR (
            overpayment_disposition='CUSTOMER_BALANCE'
            AND change_amount=0
            AND customer_balance_credit_amount>0
            AND customer_balance_ledger_entry_id IS NOT NULL
            AND tendered_amount IS NOT NULL
            AND tendered_amount-amount=customer_balance_credit_amount
        )
    );

ALTER TABLE public.customer_balance_ledger_entries
    DROP CONSTRAINT fk_customer_balance_ledger_request,
    DROP CONSTRAINT customer_balance_ledger_source_check,
    ADD CONSTRAINT customer_balance_ledger_source_check CHECK (
        source_type IN ('MANUAL_CORRECTION','SALE_OVERPAYMENT')
    );

ALTER TABLE public.customer_balance_audit
    DROP CONSTRAINT customer_balance_audit_action_check,
    ADD CONSTRAINT customer_balance_audit_action_check CHECK (
        action IN (
            'POLICY_PROVISION','POLICY_SYNC','REQUEST_CORRECTION',
            'APPROVE_CORRECTION','REJECT_CORRECTION','AUTO_DISABLE',
            'SALE_OVERPAYMENT_CREDIT'
        )
    );

ALTER TABLE public.sales_payments
    ADD CONSTRAINT fk_sales_payments_customer_balance_ledger
    FOREIGN KEY(company_id,customer_balance_ledger_entry_id)
    REFERENCES public.customer_balance_ledger_entries(company_id,id)
    ON DELETE RESTRICT;

CREATE UNIQUE INDEX uq_sales_payments_customer_balance_ledger
    ON public.sales_payments(company_id,customer_balance_ledger_entry_id)
    WHERE customer_balance_ledger_entry_id IS NOT NULL;

CREATE FUNCTION private.trg_g4_customer_balance_source_integrity()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
BEGIN
    IF NEW.source_type='MANUAL_CORRECTION' THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.customer_balance_correction_requests request
            WHERE request.company_id=NEW.company_id
              AND request.id=NEW.source_id
        ) THEN
            RAISE EXCEPTION 'CUSTOMER_BALANCE_CORRECTION_SOURCE_NOT_FOUND';
        END IF;
    ELSIF NEW.source_type='SALE_OVERPAYMENT' THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.sales_payments payment
            WHERE payment.company_id=NEW.company_id
              AND payment.id=NEW.source_id
              AND NOT payment.is_reversal
        ) THEN
            RAISE EXCEPTION 'CUSTOMER_BALANCE_SALE_PAYMENT_SOURCE_NOT_FOUND';
        END IF;
    ELSE
        RAISE EXCEPTION 'CUSTOMER_BALANCE_SOURCE_NOT_SUPPORTED';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER g4_customer_balance_source_integrity
BEFORE INSERT ON public.customer_balance_ledger_entries
FOR EACH ROW EXECUTE FUNCTION private.trg_g4_customer_balance_source_integrity();

-- Cash credited to Customer Balance stays in the drawer (no physical change
-- is returned), so expected cash includes both the Sale payment and the credit.
-- Returned Cash change continues to contribute only payment.amount.
CREATE OR REPLACE FUNCTION private.calculate_cashier_session_expected_cash(
    p_company_id UUID,
    p_cashier_session_id UUID
)
RETURNS NUMERIC
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
    SELECT session.opening_cash_actual
        + COALESCE((
            SELECT sum(CASE WHEN payment.is_reversal
                            THEN -payment.amount
                            ELSE payment.amount
                                 + payment.customer_balance_credit_amount END)
            FROM public.sales_payments payment
            JOIN public.sales_headers sale
              ON sale.company_id=payment.company_id
             AND sale.id=payment.sales_id
            LEFT JOIN public.payment_methods method
              ON method.company_id=payment.company_id
             AND method.id=payment.payment_method_id
            WHERE payment.company_id=session.company_id
              AND payment.session_id=session.id
              AND sale.invoice_status::TEXT='GENERATED'
              AND (method.method_type='CASH' OR (
                  payment.payment_method_id IS NULL
                  AND payment.payment_method::TEXT='Cash'
              ))
        ),0)
        - COALESCE((
            SELECT sum(refund.amount)
            FROM public.sales_return_refunds refund
            JOIN public.sales_return_documents document
              ON document.company_id=refund.company_id
             AND document.id=refund.document_id
             AND document.status='POSTED'
            WHERE refund.company_id=session.company_id
              AND document.executing_session_id=session.id
              AND refund.payment_method_type_snapshot='CASH'
        ),0)
        + COALESCE((
            SELECT sum(CASE WHEN movement.direction='IN'
                            THEN movement.amount ELSE -movement.amount END)
            FROM public.cash_drawer_movements movement
            WHERE movement.company_id=session.company_id
              AND movement.cashier_session_id=session.id
        ),0)
    FROM public.cashier_sessions session
    WHERE session.company_id=p_company_id
      AND session.id=p_cashier_session_id;
$$;

-- Preserve the Phase-4 posting implementation as the online final-effect
-- engine. The new core wraps it in the same SQL transaction and adds only the
-- optional overpayment credit after Sale/Payment rows exist.
ALTER FUNCTION private.post_pos_sale_core(UUID,BIGINT,UUID)
    RENAME TO post_pos_sale_online_core;

CREATE FUNCTION private.post_pos_sale_core(
    p_sales_id UUID,
    p_master_version BIGINT,
    p_posting_idempotency_key UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_actor UUID:=auth.uid();
    v_company UUID:=public.private_active_company_id();
    v_sale public.sales_headers%ROWTYPE;
    v_customer public.customers%ROWTYPE;
    v_result JSONB;
    v_leg RECORD;
    v_disposition TEXT;
    v_overpayment NUMERIC(20,4);
    v_before NUMERIC(20,4);
    v_after NUMERIC(20,4);
    v_credit_total NUMERIC(20,4):=0;
    v_category UUID;
    v_liability UUID;
    v_source UUID;
    v_source_function TEXT;
    v_event UUID;
    v_entry UUID;
    v_entry_no BIGINT;
    v_idempotency UUID;
    v_payload_hash TEXT;
    v_policy TEXT;
    v_feature_enabled BOOLEAN;
    v_now TIMESTAMPTZ:=clock_timestamp();
BEGIN
    v_result:=private.post_pos_sale_online_core(
        p_sales_id,p_master_version,p_posting_idempotency_key
    );
    IF v_result->>'documentStatus'<>'POSTED' THEN
        RETURN v_result;
    END IF;

    SELECT * INTO v_sale
    FROM public.sales_headers sale
    WHERE sale.company_id=v_company AND sale.id=p_sales_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'SALE_NOT_FOUND_AFTER_POST'; END IF;

    FOR v_leg IN
        WITH payload_legs AS (
            SELECT value AS payload,ordinality
            FROM jsonb_array_elements(
                COALESCE(v_sale.payload_snapshot->'payments','[]'::JSONB)
            ) WITH ORDINALITY
        ), payment_rows AS (
            SELECT payment.*,
                   row_number() OVER(ORDER BY payment.payment_no) AS ordinality
            FROM public.sales_payments payment
            WHERE payment.company_id=v_company
              AND payment.sales_id=p_sales_id
              AND NOT payment.is_reversal
        )
        SELECT payload_legs.payload,payment_rows.*
        FROM payload_legs
        JOIN payment_rows USING(ordinality)
        ORDER BY payload_legs.ordinality
    LOOP
        v_overpayment:=GREATEST(COALESCE(v_leg.change_amount,0),0);
        v_disposition:=upper(btrim(COALESCE(
            v_leg.payload->>'overpaymentDisposition',''
        )));

        IF v_leg.customer_balance_ledger_entry_id IS NOT NULL THEN
            IF v_leg.overpayment_disposition<>'CUSTOMER_BALANCE'
               OR v_leg.customer_balance_credit_amount<=0 THEN
                RAISE EXCEPTION 'CUSTOMER_BALANCE_PAYMENT_SNAPSHOT_INVALID';
            END IF;
            v_credit_total:=v_credit_total
                + v_leg.customer_balance_credit_amount;
            CONTINUE;
        END IF;

        IF v_overpayment=0 THEN
            IF v_disposition NOT IN ('','NONE') THEN
                RAISE EXCEPTION 'OVERPAYMENT_DISPOSITION_WITHOUT_OVERPAYMENT';
            END IF;
            UPDATE public.sales_payments
            SET overpayment_disposition='NONE'
            WHERE company_id=v_company AND id=v_leg.id;
            CONTINUE;
        END IF;

        -- Compatibility: existing/new Cash payloads without the Phase-53 UI
        -- field continue to mean physical change returned to the Customer.
        IF v_disposition='' AND v_leg.payment_method_type_snapshot='CASH' THEN
            v_disposition:='RETURNED';
        ELSIF v_disposition='' THEN
            RAISE EXCEPTION 'OVERPAYMENT_DISPOSITION_REQUIRED';
        END IF;

        IF v_disposition='RETURNED' THEN
            IF v_leg.payment_method_type_snapshot NOT IN ('CASH','TRANSFER') THEN
                RAISE EXCEPTION 'OVERPAYMENT_RETURN_METHOD_NOT_SUPPORTED';
            END IF;
            UPDATE public.sales_payments
            SET overpayment_disposition='RETURNED'
            WHERE company_id=v_company AND id=v_leg.id;
            CONTINUE;
        END IF;

        IF v_disposition<>'CUSTOMER_BALANCE' THEN
            RAISE EXCEPTION 'OVERPAYMENT_DISPOSITION_INVALID';
        END IF;
        IF v_sale.source_channel<>'ONLINE' THEN
            RAISE EXCEPTION 'OFFLINE_CUSTOMER_BALANCE_CREDIT_NOT_ENABLED';
        END IF;
        IF v_leg.payment_method_type_snapshot NOT IN ('CASH','TRANSFER') THEN
            RAISE EXCEPTION 'CUSTOMER_BALANCE_CREDIT_METHOD_NOT_SUPPORTED';
        END IF;

        SELECT * INTO v_customer
        FROM public.customers customer
        WHERE customer.company_id=v_company
          AND customer.id=v_sale.customer_id
        FOR UPDATE;
        IF NOT FOUND OR NOT v_customer.is_active
           OR v_customer.is_system_customer THEN
            RAISE EXCEPTION 'CUSTOMER_BALANCE_ELIGIBLE_CUSTOMER_REQUIRED';
        END IF;

        SELECT EXISTS(
            SELECT 1 FROM public.company_features feature
            WHERE feature.company_id=v_company
              AND feature.feature_code='customer_balance_enabled'
              AND feature.is_enabled
        ) INTO v_feature_enabled;
        SELECT policy.lifecycle_state INTO v_policy
        FROM public.customer_balance_company_policies policy
        WHERE policy.company_id=v_company
        FOR UPDATE;
        IF NOT COALESCE(v_feature_enabled,FALSE)
           OR v_policy IS DISTINCT FROM 'ACTIVE' THEN
            RAISE EXCEPTION 'CUSTOMER_BALANCE_CREDIT_DISABLED';
        END IF;

        SELECT category.id INTO v_category
        FROM public.transaction_categories category
        WHERE category.company_id=v_company
          AND category.system_key='CUSTOMER_BALANCE_RECEIPT'
          AND category.is_active
        ORDER BY category.is_system_default DESC,category.id LIMIT 1;
        IF v_category IS NULL THEN
            RAISE EXCEPTION 'CUSTOMER_BALANCE_TRANSACTION_CATEGORY_NOT_FOUND';
        END IF;

        v_source_function:=CASE
            WHEN v_leg.payment_method_type_snapshot='CASH' THEN 'CASH_DRAWER'
            ELSE 'BANK'
        END;
        v_liability:=private.resolve_customer_balance_account(
            v_company,v_category,'CUSTOMER_BALANCE_LIABILITY',v_now
        );
        v_source:=private.resolve_customer_balance_account(
            v_company,v_category,v_source_function,v_now
        );

        v_before:=v_customer.current_balance;
        v_after:=v_before+v_overpayment;
        v_idempotency:=(
            substr(md5(v_company::TEXT||'|'||v_leg.id::TEXT||
                '|SALE_OVERPAYMENT'),1,8)||'-'||
            substr(md5(v_company::TEXT||'|'||v_leg.id::TEXT||
                '|SALE_OVERPAYMENT'),9,4)||'-'||
            substr(md5(v_company::TEXT||'|'||v_leg.id::TEXT||
                '|SALE_OVERPAYMENT'),13,4)||'-'||
            substr(md5(v_company::TEXT||'|'||v_leg.id::TEXT||
                '|SALE_OVERPAYMENT'),17,4)||'-'||
            substr(md5(v_company::TEXT||'|'||v_leg.id::TEXT||
                '|SALE_OVERPAYMENT'),21,12)
        )::UUID;
        v_payload_hash:=encode(extensions.digest(convert_to(
            concat_ws('|',v_company,v_sale.id,v_leg.id,v_customer.id,
                v_overpayment,v_source_function,v_leg.proof_url),
            'UTF8'
        ),'sha256'),'hex');

        INSERT INTO public.financial_events(
            event_code,event_type,source_table,source_id,root_sales_id,
            event_date,event_version,idempotency_key,payment_method,amounts,
            status,error_message,created_by,company_id,store_id,
            system_event_key,transaction_category_id
        ) VALUES(
            'CB-SALE-'||replace(v_leg.id::TEXT,'-',''),
            'CUSTOMER_BALANCE_ADJUSTMENT'::public.event_type,
            'sales_payments',v_leg.id,v_sale.id,v_now,1,
            'SALE_OVERPAYMENT|'||v_company::TEXT||'|'||v_leg.id::TEXT,
            v_leg.payment_method_name_snapshot,jsonb_build_object(
                'saleId',v_sale.id,'invoiceNo',v_sale.invoice_no,
                'paymentId',v_leg.id,'customerId',v_customer.id,
                'direction','CREDIT','amount',v_overpayment,
                'balanceBefore',v_before,'balanceAfter',v_after,
                'liabilityAccountId',v_liability,
                'sourceAccountId',v_source,
                'sourceAccountFunction',v_source_function,
                'financePostingState','HOLD_UNTIL_G6'
            ),'HOLD'::public.event_status,
            'CANONICAL_FINANCE_POSTING_NOT_ENABLED',v_actor,v_company,
            v_sale.store_id,'CUSTOMER_BALANCE_RECEIPT',v_category
        ) RETURNING id INTO v_event;

        v_entry_no:=nextval('private.customer_balance_request_no_seq');
        INSERT INTO public.customer_balance_ledger_entries(
            company_id,customer_id,store_id,entry_no,direction,amount,
            source_type,source_id,source_reference,reason,evidence_url,
            balance_before,balance_after,transaction_category_id,
            liability_account_id,source_account_id,source_account_function,
            financial_event_id,idempotency_key,payload_hash,created_by
        ) VALUES(
            v_company,v_customer.id,v_sale.store_id,v_entry_no,'CREDIT',
            v_overpayment,'SALE_OVERPAYMENT',v_leg.id,
            COALESCE(NULLIF(v_sale.invoice_no,''),v_leg.payment_no),
            'Kelebihan pembayaran disimpan sebagai Saldo Customer',
            v_leg.proof_url,v_before,v_after,v_category,v_liability,v_source,
            v_source_function,v_event,v_idempotency,v_payload_hash,v_actor
        ) RETURNING id INTO v_entry;

        UPDATE public.customers
        SET current_balance=v_after,updated_by=v_actor
        WHERE company_id=v_company AND id=v_customer.id;
        UPDATE public.sales_payments
        SET overpayment_disposition='CUSTOMER_BALANCE',
            customer_balance_credit_amount=v_overpayment,
            customer_balance_ledger_entry_id=v_entry,
            change_amount=0
        WHERE company_id=v_company AND id=v_leg.id;
        INSERT INTO public.customer_balance_audit(
            company_id,customer_id,correction_request_id,action,actor_id,
            before_state,after_state
        ) VALUES(
            v_company,v_customer.id,NULL,'SALE_OVERPAYMENT_CREDIT',v_actor,
            jsonb_build_object('balance',v_before,'paymentId',v_leg.id),
            jsonb_build_object('balance',v_after,'paymentId',v_leg.id,
                'ledgerEntryId',v_entry,'amount',v_overpayment)
        );
        v_credit_total:=v_credit_total+v_overpayment;
    END LOOP;

    RETURN v_result||jsonb_build_object(
        'customerBalanceCreditTotal',v_credit_total
    );
END;
$$;

-- Recompile the public wrapper so it binds to the new private core OID, then
-- retain Payment-Leg identity mapping and rebuild the returned receipt from
-- authoritative Payment snapshots after credit/change disposition.
CREATE OR REPLACE FUNCTION public.post_pos_sale(
    p_sales_id UUID,
    p_master_version BIGINT,
    p_posting_idempotency_key UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_actor UUID:=auth.uid();
    v_company UUID:=public.private_active_company_id();
    v_sale public.sales_headers%ROWTYPE;
    v_result JSONB;
    v_expected_legs BIGINT;
    v_mapped_legs BIGINT;
    v_receipt JSONB;
BEGIN
    SELECT * INTO v_sale
    FROM public.sales_headers sale
    WHERE sale.company_id=v_company AND sale.id=p_sales_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SALE_DRAFT_NOT_FOUND'; END IF;
    IF v_sale.document_status='DRAFT' AND (
        v_sale.edit_lock_owner_id IS DISTINCT FROM v_actor
        OR v_sale.edit_lock_session_id IS DISTINCT FROM v_sale.session_id
        OR v_sale.edit_lock_heartbeat_at IS NULL
        OR v_sale.edit_lock_heartbeat_at<clock_timestamp()-interval '5 minutes'
    ) THEN
        RAISE EXCEPTION 'SALE_DRAFT_EDIT_LOCK_REQUIRED';
    END IF;

    v_result:=private.post_pos_sale_core(
        p_sales_id,p_master_version,p_posting_idempotency_key
    );
    IF v_result->>'documentStatus'='POSTED' THEN
        SELECT * INTO v_sale FROM public.sales_headers
        WHERE company_id=v_company AND id=p_sales_id;
        v_expected_legs:=COALESCE(
            jsonb_array_length(v_sale.payload_snapshot->'payments'),0
        );
        WITH payload_legs AS (
            SELECT ordinality,
                (value->>'clientPaymentKey')::UUID AS client_payment_key
            FROM jsonb_array_elements(COALESCE(
                v_sale.payload_snapshot->'payments','[]'::JSONB
            )) WITH ORDINALITY
        ), payment_rows AS (
            SELECT payment.id,
                row_number() OVER(ORDER BY payment.payment_no) AS ordinality
            FROM public.sales_payments payment
            WHERE payment.company_id=v_company
              AND payment.sales_id=p_sales_id AND NOT payment.is_reversal
        ), mapped AS (
            UPDATE public.sales_payments payment
            SET client_payment_key=payload_legs.client_payment_key
            FROM payload_legs
            JOIN payment_rows USING(ordinality)
            WHERE payment.id=payment_rows.id
            RETURNING payment.id
        ) SELECT count(*) INTO v_mapped_legs FROM mapped;
        IF v_mapped_legs<>v_expected_legs THEN
            RAISE EXCEPTION 'PAYMENT_LEG_IDENTITY_MAPPING_FAILED';
        END IF;

        SELECT jsonb_set(
            v_sale.receipt_snapshot,'{payments}',COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                    'clientPaymentKey',payment.client_payment_key,
                    'paymentMethodName',payment.payment_method_name_snapshot,
                    'paymentMethodType',payment.payment_method_type_snapshot,
                    'amount',payment.amount,
                    'configuredFee',payment.configured_fee_amount,
                    'customerSurcharge',payment.customer_surcharge_amount,
                    'tenderedAmount',payment.tendered_amount,
                    'changeAmount',payment.change_amount,
                    'overpaymentDisposition',payment.overpayment_disposition,
                    'customerBalanceCreditAmount',
                        payment.customer_balance_credit_amount,
                    'customerBalanceLedgerEntryId',
                        payment.customer_balance_ledger_entry_id,
                    'proofUrl',payment.proof_url
                ) ORDER BY payment.payment_no)
                FROM public.sales_payments payment
                WHERE payment.company_id=v_company
                  AND payment.sales_id=p_sales_id
                  AND NOT payment.is_reversal
            ),'[]'::JSONB),TRUE
        ) INTO v_receipt;
        UPDATE public.sales_headers
        SET receipt_snapshot=v_receipt,
            edit_lock_owner_id=NULL,edit_lock_session_id=NULL,
            edit_lock_acquired_at=NULL,edit_lock_heartbeat_at=NULL
        WHERE company_id=v_company AND id=p_sales_id;
        v_result:=v_result||jsonb_build_object('receipt',v_receipt);
    END IF;
    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g4_customer_balance_source_integrity(),
    private.calculate_cashier_session_expected_cash(UUID,UUID),
    private.post_pos_sale_online_core(UUID,BIGINT,UUID),
    private.post_pos_sale_core(UUID,BIGINT,UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.trg_g4_customer_balance_source_integrity(),
    private.calculate_cashier_session_expected_cash(UUID,UUID),
    private.post_pos_sale_online_core(UUID,BIGINT,UUID),
    private.post_pos_sale_core(UUID,BIGINT,UUID)
TO service_role;

REVOKE ALL ON FUNCTION public.post_pos_sale(UUID,BIGINT,UUID)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.post_pos_sale(UUID,BIGINT,UUID)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
    '20260805130000','g4_phase52_customer_balance_sale_credit',
    'Atomic ONLINE Sale overpayment disposition, append-only Customer Balance credit, Payment/receipt snapshots, cache reconciliation, audit, and Finance HOLD'
);

COMMIT;
