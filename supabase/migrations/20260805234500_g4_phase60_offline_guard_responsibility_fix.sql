-- G4 phase 60 forward fix 3: the Offline reservation trigger protects only
-- active Offline reservations. Negative-stock authorization remains enforced
-- by the canonical Sale authorization and negative Movement guard.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260805233000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Phase-60 marker fix is incomplete';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260805234500'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260805234500';
    END IF;
END
$migration_guard$;

DROP TRIGGER IF EXISTS g4_mark_negative_stock_authorization
ON public.pos_negative_stock_authorizations;
DROP FUNCTION IF EXISTS private.trg_g4_mark_negative_stock_authorization();

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

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g4_guard_offline_reserved_stock()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g4_guard_offline_reserved_stock()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
    '20260805234500',
    'g4_phase60_offline_guard_responsibility_fix',
    'Forward fix 3: Offline trigger protects active reserved quantity only; canonical Sale authorization and negative Movement guard remain authoritative'
);

COMMIT;
