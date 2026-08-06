-- G4 phase 60 forward fix: preserve Offline reservations while allowing an
-- explicitly authorized online Sale to cross below zero.

BEGIN;

DO $migration_guard$
DECLARE
    v_definition TEXT;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260805220000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G4 phase 60 is incomplete';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260805230000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260805230000';
    END IF;

    SELECT pg_get_functiondef(
        'private.trg_g4_guard_offline_reserved_stock()'::regprocedure
    ) INTO v_definition;
    IF v_definition !~ 'NEW.stock_qty < v_reserved'
       OR v_definition ~ 'pos_negative_stock_authorizations' THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Offline stock guard changed';
    END IF;
END
$migration_guard$;

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
        osa.allocated_base_qty - osa.consumed_base_qty
    ),0)
    INTO v_reserved
    FROM public.pos_offline_stock_allowances osa
    WHERE osa.company_id = v_company
      AND osa.warehouse_id = v_warehouse
      AND osa.product_id = v_product
      AND osa.status = 'ACTIVE';

    IF TG_OP = 'DELETE' THEN
        IF v_reserved > 0 THEN
            RAISE EXCEPTION 'STOCK_RESERVED_FOR_OFFLINE_ALLOWANCE';
        END IF;
        RETURN OLD;
    END IF;

    -- Physical stock reserved for an Offline Session remains untouchable by
    -- every online path, including the negative-stock exception.
    IF v_reserved > 0 AND NEW.stock_qty < v_reserved THEN
        RAISE EXCEPTION 'STOCK_RESERVED_FOR_OFFLINE_ALLOWANCE';
    END IF;

    IF NEW.stock_qty >= v_reserved THEN
        RETURN NEW;
    END IF;

    -- With no Offline reservation, an incoming replenishment may move an
    -- already-negative balance toward zero before all shortage is covered.
    IF v_reserved = 0
       AND TG_OP = 'UPDATE'
       AND NEW.stock_qty > OLD.stock_qty THEN
        RETURN NEW;
    END IF;

    -- A decrease below zero is legal only inside the same online Sale
    -- transaction that created the Phase-60 authorization for this exact
    -- Product/Warehouse/resulting balance. A stale authorization cannot be
    -- reused because its Sale is no longer DRAFT and its timestamp predates
    -- the current transaction.
    IF v_reserved = 0
       AND NEW.stock_qty < 0
       AND EXISTS (
           SELECT 1
           FROM public.pos_negative_stock_authorizations authz
           JOIN public.sales_headers sale
             ON sale.company_id = authz.company_id
            AND sale.id = authz.sales_id
           WHERE authz.company_id = v_company
             AND authz.stock_product_id = v_product
             AND authz.warehouse_id = v_warehouse
             AND authz.balance_after_base_qty = NEW.stock_qty
             AND authz.actor_id = auth.uid()
             AND authz.created_at >= transaction_timestamp()
             AND sale.document_status::TEXT = 'DRAFT'
       ) THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'STOCK_RESERVED_FOR_OFFLINE_ALLOWANCE';
END;
$$;

-- The original foundation only guarded UPDATE and DELETE. INSERT is added so
-- an absent Product/Warehouse balance cannot bypass the same contract.
DROP TRIGGER IF EXISTS g4_guard_offline_reserved_stock_insert
ON public.product_stocks;
CREATE TRIGGER g4_guard_offline_reserved_stock_insert
BEFORE INSERT ON public.product_stocks
FOR EACH ROW EXECUTE FUNCTION private.trg_g4_guard_offline_reserved_stock();

REVOKE ALL ON FUNCTION private.trg_g4_guard_offline_reserved_stock()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g4_guard_offline_reserved_stock()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
    '20260805230000',
    'g4_phase60_offline_reservation_guard_fix',
    'Forward fix: Offline reservation remains protected while same-transaction authorized online negative Sale and replenishment are permitted'
);

COMMIT;
