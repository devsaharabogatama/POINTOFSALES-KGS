-- G4 phase 60 forward fix 2: bind a negative stock mutation to the exact
-- transaction that inserted its server-side authorization.

BEGIN;

DO $migration_guard$
DECLARE
    v_definition TEXT;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260805230000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: first Phase-60 guard fix is incomplete';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260805233000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260805233000';
    END IF;

    SELECT pg_get_functiondef(
        'private.trg_g4_guard_offline_reserved_stock()'::regprocedure
    ) INTO v_definition;
    IF v_definition !~* 'pos_negative_stock_authorizations'
       OR v_definition ~* 'kgs\.negative_stock_sale_id' THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Phase-60 guard fix changed';
    END IF;
END
$migration_guard$;

CREATE FUNCTION private.trg_g4_mark_negative_stock_authorization()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM set_config(
        'kgs.negative_stock_sale_id',NEW.sales_id::TEXT,TRUE
    );
    RETURN NEW;
END;
$$;

CREATE TRIGGER g4_mark_negative_stock_authorization
AFTER INSERT ON public.pos_negative_stock_authorizations
FOR EACH ROW
EXECUTE FUNCTION private.trg_g4_mark_negative_stock_authorization();

CREATE OR REPLACE FUNCTION private.trg_g4_guard_offline_reserved_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_reserved NUMERIC(24,6);
    v_company UUID;
    v_warehouse UUID;
    v_product UUID;
    v_authorized_sale_id UUID;
BEGIN
    IF TG_OP = 'UPDATE'
       AND NEW.stock_qty IS NOT DISTINCT FROM OLD.stock_qty THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        v_company := OLD.company_id;
        v_warehouse := OLD.warehouse_id;
        v_product := OLD.product_id;
    ELSE
        v_company := NEW.company_id;
        v_warehouse := NEW.warehouse_id;
        v_product := NEW.product_id;
    END IF;

    SELECT COALESCE(sum(
        allowance.allocated_base_qty - allowance.consumed_base_qty
    ),0)
    INTO v_reserved
    FROM public.pos_offline_stock_allowances allowance
    WHERE allowance.company_id = v_company
      AND allowance.warehouse_id = v_warehouse
      AND allowance.product_id = v_product
      AND allowance.status = 'ACTIVE';

    IF TG_OP = 'DELETE' THEN
        IF v_reserved > 0 THEN
            RAISE EXCEPTION 'STOCK_RESERVED_FOR_OFFLINE_ALLOWANCE';
        END IF;
        RETURN OLD;
    END IF;

    IF v_reserved > 0 AND NEW.stock_qty < v_reserved THEN
        RAISE EXCEPTION 'STOCK_RESERVED_FOR_OFFLINE_ALLOWANCE';
    END IF;

    IF NEW.stock_qty >= v_reserved THEN
        RETURN NEW;
    END IF;

    IF v_reserved = 0
       AND TG_OP = 'UPDATE'
       AND NEW.stock_qty > OLD.stock_qty THEN
        RETURN NEW;
    END IF;

    BEGIN
        v_authorized_sale_id := NULLIF(
            current_setting('kgs.negative_stock_sale_id',TRUE),''
        )::UUID;
    EXCEPTION WHEN invalid_text_representation THEN
        v_authorized_sale_id := NULL;
    END;

    IF v_reserved = 0
       AND NEW.stock_qty < 0
       AND v_authorized_sale_id IS NOT NULL
       AND EXISTS (
           SELECT 1
           FROM public.pos_negative_stock_authorizations authz
           WHERE authz.company_id = v_company
             AND authz.sales_id = v_authorized_sale_id
             AND authz.stock_product_id = v_product
             AND authz.warehouse_id = v_warehouse
             AND authz.balance_after_base_qty = NEW.stock_qty
       ) THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'STOCK_RESERVED_FOR_OFFLINE_ALLOWANCE';
END;
$$;

REVOKE ALL ON FUNCTION
    private.trg_g4_mark_negative_stock_authorization(),
    private.trg_g4_guard_offline_reserved_stock()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.trg_g4_mark_negative_stock_authorization(),
    private.trg_g4_guard_offline_reserved_stock()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
    '20260805233000',
    'g4_phase60_authorization_transaction_marker_fix',
    'Forward fix 2: transaction-local authorization marker binds the exact online Sale to its negative stock mutation'
);

COMMIT;
