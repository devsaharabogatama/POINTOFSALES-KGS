-- Fresh-install bridge for legacy runtime objects that existed before G1 but
-- were historically installed from standalone SQL files after migration 002.
-- Canonical forward migrations quarantine or replace these signatures. The
-- bridge preserves only the dependency contract required to replay that chain.

CREATE SEQUENCE IF NOT EXISTS public.financial_event_code_seq;
CREATE SEQUENCE IF NOT EXISTS public.journal_no_seq;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    INSERT INTO public.profiles(id,email,name,role)
    VALUES (
        NEW.id,
        NEW.email,
        COALESCE(
            NEW.raw_user_meta_data->>'name',
            split_part(NEW.email,'@',1)
        ),
        'cashier'::public.user_role
    )
    ON CONFLICT(id) DO NOTHING;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

CREATE OR REPLACE FUNCTION public.trg_cash_advances_to_financial_events()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    -- The canonical Expense migration requires the historical trigger shape
    -- and disables it before opening the replacement workflow.
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS cash_advances_financial_event_trigger
    ON public.cash_advances;
CREATE TRIGGER cash_advances_financial_event_trigger
AFTER INSERT OR UPDATE ON public.cash_advances
FOR EACH ROW
EXECUTE FUNCTION public.trg_cash_advances_to_financial_events();

CREATE OR REPLACE FUNCTION public.trg_bank_deposits_to_financial_events()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS bank_deposits_financial_event_trigger
    ON public.bank_deposits;
CREATE TRIGGER bank_deposits_financial_event_trigger
AFTER INSERT ON public.bank_deposits
FOR EACH ROW
EXECUTE FUNCTION public.trg_bank_deposits_to_financial_events();

CREATE OR REPLACE FUNCTION public.process_financial_events_queue()
RETURNS JSONB
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'LEGACY_FINANCE_WORKER_RETIRED';
END;
$$;

CREATE OR REPLACE FUNCTION public.create_sales_transaction(
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
BEGIN
    RAISE EXCEPTION 'LEGACY_CHECKOUT_ROUTINE_RETIRED';
END;
$$;

REVOKE ALL ON FUNCTION public.process_financial_events_queue()
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.transfer_product_stock(
    UUID, UUID, UUID, NUMERIC
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_sales_transaction(
    TEXT, UUID, UUID, BOOLEAN, TIMESTAMPTZ, BOOLEAN, TEXT,
    NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC,
    public.payment_status, UUID, JSONB, JSONB, JSONB
) FROM PUBLIC, anon, authenticated;
