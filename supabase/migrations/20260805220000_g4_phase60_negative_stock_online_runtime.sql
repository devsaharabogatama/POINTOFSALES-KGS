-- G4 phase 60: controlled online Sale negative-stock runtime and automatic
-- replenishment reconciliation. Feature/configuration remain default OFF.
BEGIN;

DO $guard$
DECLARE v_definition TEXT;
BEGIN
    IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260805190000') THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: phase58';
    END IF;
    IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260805220000') THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260805220000';
    END IF;
    IF EXISTS(SELECT 1 FROM public.product_stocks WHERE stock_qty<0)
       OR EXISTS(SELECT 1 FROM public.pos_negative_stock_authorizations)
       OR EXISTS(SELECT 1 FROM public.negative_stock_sale_allocations) THEN
        RAISE EXCEPTION 'G4_PHASE60_STATE_CHANGED: negative runtime history exists';
    END IF;
    SELECT pg_get_functiondef(
        'private.post_pos_sale_online_core(uuid,bigint,uuid)'::regprocedure
    ) INTO v_definition;
    IF v_definition!~'STOCK_SHORTAGE'
       OR v_definition~'pos_negative_stock_authorizations' THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Sale core changed';
    END IF;
END
$guard$;

ALTER TABLE public.stock_movements
    DROP CONSTRAINT stock_movements_balance_after_nonnegative,
    ADD CONSTRAINT stock_movements_balance_after_controlled CHECK(
        balance_after_base_qty IS NULL
        OR balance_after_base_qty>=0
        OR (
            movement_type='SALE'::public.stock_movement_type
            AND reference_table='sales_headers'
            AND movement_status='POSTED'
        )
    );

CREATE FUNCTION private.resolve_pos_negative_stock_provisional_cost(
    p_company_id UUID,p_product_id UUID,p_warehouse_id UUID
) RETURNS NUMERIC(20,4) LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_cost NUMERIC(20,4);
BEGIN
    SELECT batch.cogs_unit INTO v_cost
    FROM public.product_batches batch
    WHERE batch.company_id=p_company_id AND batch.product_id=p_product_id
      AND batch.warehouse_id=p_warehouse_id AND batch.cogs_unit>=0
    ORDER BY batch.created_at DESC,batch.id DESC LIMIT 1;
    IF v_cost IS NULL THEN
        SELECT product.cogs INTO v_cost FROM public.products product
        WHERE product.company_id=p_company_id AND product.id=p_product_id
          AND product.is_active AND NOT product.is_bundle;
    END IF;
    IF v_cost IS NULL OR v_cost<0 THEN
        RAISE EXCEPTION 'NEGATIVE_STOCK_PROVISIONAL_COST_NOT_FOUND';
    END IF;
    RETURN v_cost;
END;
$$;

CREATE FUNCTION private.authorize_pos_negative_stock(
    p_company_id UUID,p_sales_id UUID,p_warehouse_id UUID,
    p_actor_id UUID,p_shortages JSONB,p_reason TEXT
) RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_policy public.pos_negative_stock_policies%ROWTYPE;
    v_permission public.pos_negative_stock_permissions%ROWTYPE;
    v_item JSONB; v_product UUID; v_detail UUID;
    v_requested NUMERIC(24,6); v_available NUMERIC(24,6);
    v_shortage NUMERIC(24,6); v_balance NUMERIC(24,6);
    v_cost NUMERIC(20,4); v_reason TEXT:=NULLIF(btrim(p_reason),'');
BEGIN
    IF jsonb_typeof(p_shortages)<>'array' OR jsonb_array_length(p_shortages)=0
    THEN RETURN FALSE; END IF;
    IF NOT EXISTS(SELECT 1 FROM public.company_features feature
        WHERE feature.company_id=p_company_id
          AND feature.feature_code='pos_negative_stock_enabled'
          AND feature.is_enabled) THEN RETURN FALSE; END IF;
    SELECT * INTO v_policy FROM public.pos_negative_stock_policies policy
    WHERE policy.company_id=p_company_id AND policy.is_active FOR UPDATE;
    IF NOT FOUND THEN RETURN FALSE; END IF;
    IF NOT EXISTS(SELECT 1 FROM public.warehouses warehouse
        WHERE warehouse.company_id=p_company_id AND warehouse.id=p_warehouse_id
          AND warehouse.is_active AND warehouse.is_sale_source
          AND warehouse.allow_negative_stock) THEN RETURN FALSE; END IF;
    SELECT * INTO v_permission
    FROM public.pos_negative_stock_permissions permission
    WHERE permission.company_id=p_company_id
      AND permission.warehouse_id=p_warehouse_id
      AND permission.user_id=p_actor_id AND permission.is_active
      AND (permission.valid_until IS NULL
           OR permission.valid_until>clock_timestamp())
    FOR UPDATE;
    IF NOT FOUND THEN RETURN FALSE; END IF;
    IF v_policy.require_reason AND v_reason IS NULL THEN
        RAISE EXCEPTION 'NEGATIVE_STOCK_REASON_REQUIRED';
    END IF;
    v_reason:=COALESCE(v_reason,'Policy-approved negative stock');

    IF EXISTS(
        SELECT 1 FROM jsonb_array_elements(p_shortages) item
        JOIN public.sale_stock_requirements requirement
          ON requirement.company_id=p_company_id
         AND requirement.sales_id=p_sales_id
         AND requirement.stock_product_id=(item->>'productId')::UUID
        JOIN public.products commercial
          ON commercial.company_id=requirement.company_id
         AND commercial.id=requirement.commercial_product_id
         AND commercial.is_bundle
    ) THEN RETURN FALSE; END IF;

    FOR v_item IN SELECT value FROM jsonb_array_elements(p_shortages)
    LOOP
        v_product:=(v_item->>'productId')::UUID;
        SELECT sum(requirement.quantity_base),
               min(requirement.sales_detail_id::TEXT)::UUID
        INTO v_requested,v_detail
        FROM public.sale_stock_requirements requirement
        WHERE requirement.company_id=p_company_id
          AND requirement.sales_id=p_sales_id
          AND requirement.stock_product_id=v_product;
        SELECT GREATEST(LEAST(COALESCE(stock.stock_qty,0),COALESCE((
            SELECT sum(batch.qty_remaining) FROM public.product_batches batch
            WHERE batch.company_id=p_company_id AND batch.product_id=v_product
              AND batch.warehouse_id=p_warehouse_id
              AND batch.qty_remaining>0
        ),0)),0),COALESCE(stock.stock_qty,0)-v_requested
        INTO v_available,v_balance
        FROM (SELECT 1) seed LEFT JOIN public.product_stocks stock
          ON stock.company_id=p_company_id AND stock.product_id=v_product
         AND stock.warehouse_id=p_warehouse_id;
        v_shortage:=v_requested-v_available;
        IF v_shortage<=0 OR v_balance>=0 THEN CONTINUE; END IF;
        IF v_policy.company_negative_limit_base_qty IS NOT NULL
           AND abs(v_balance)>v_policy.company_negative_limit_base_qty THEN
            RAISE EXCEPTION 'COMPANY_NEGATIVE_STOCK_LIMIT_EXCEEDED';
        END IF;
        IF v_permission.max_negative_base_qty IS NOT NULL
           AND abs(v_balance)>v_permission.max_negative_base_qty THEN
            RAISE EXCEPTION 'USER_NEGATIVE_STOCK_LIMIT_EXCEEDED';
        END IF;
        v_cost:=private.resolve_pos_negative_stock_provisional_cost(
            p_company_id,v_product,p_warehouse_id
        );
        INSERT INTO public.pos_negative_stock_authorizations(
            company_id,sales_id,sales_detail_id,stock_product_id,warehouse_id,
            permission_id,actor_id,reason,requested_base_qty,
            available_base_qty,shortage_base_qty,balance_after_base_qty,
            provisional_unit_cost,policy_version,permission_version
        ) VALUES(
            p_company_id,p_sales_id,v_detail,v_product,p_warehouse_id,
            v_permission.id,p_actor_id,v_reason,v_requested,v_available,
            v_shortage,v_balance,v_cost,v_policy.master_version,
            v_permission.master_version
        );
    END LOOP;
    RETURN EXISTS(SELECT 1 FROM public.pos_negative_stock_authorizations authz
        WHERE authz.company_id=p_company_id AND authz.sales_id=p_sales_id);
END;
$$;

CREATE FUNCTION private.reconcile_negative_stock_replenishment()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_allocation public.negative_stock_sale_allocations%ROWTYPE;
    v_available NUMERIC(24,6):=NEW.qty_remaining;
    v_outstanding NUMERIC(24,6); v_take NUMERIC(24,6);
    v_actual NUMERIC(20,4); v_variance NUMERIC(20,4);
BEGIN
    IF v_available<=0 THEN RETURN NEW; END IF;
    FOR v_allocation IN
        SELECT * FROM public.negative_stock_sale_allocations allocation
        WHERE allocation.company_id=NEW.company_id
          AND allocation.stock_product_id=NEW.product_id
          AND allocation.warehouse_id=NEW.warehouse_id
          AND allocation.reconciled_at IS NULL
        ORDER BY allocation.created_at,allocation.id FOR UPDATE
    LOOP
        EXIT WHEN v_available<=0;
        v_outstanding:=v_allocation.shortage_base_qty
            -v_allocation.replenished_base_qty;
        v_take:=LEAST(v_available,v_outstanding);
        v_actual:=round(v_take*NEW.cogs_unit,4);
        v_variance:=v_actual-round(
            v_take*v_allocation.provisional_unit_cost,4
        );
        INSERT INTO public.negative_stock_replenishment_allocations(
            company_id,negative_sale_allocation_id,product_batch_id,
            replenished_base_qty,provisional_unit_cost,actual_unit_cost,
            cost_variance_total
        ) VALUES(
            NEW.company_id,v_allocation.id,NEW.id,v_take,
            v_allocation.provisional_unit_cost,NEW.cogs_unit,v_variance
        );
        UPDATE public.negative_stock_sale_allocations SET
            replenished_base_qty=replenished_base_qty+v_take,
            actual_cost_total=actual_cost_total+v_actual,
            cost_variance_total=cost_variance_total+v_variance,
            reconciled_at=CASE
                WHEN replenished_base_qty+v_take=shortage_base_qty
                THEN clock_timestamp() ELSE NULL END
        WHERE company_id=NEW.company_id AND id=v_allocation.id;
        v_available:=v_available-v_take;
    END LOOP;
    IF v_available IS DISTINCT FROM NEW.qty_remaining THEN
        UPDATE public.product_batches SET qty_remaining=v_available
        WHERE company_id=NEW.company_id AND id=NEW.id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER g4_reconcile_negative_stock_replenishment
AFTER INSERT ON public.product_batches FOR EACH ROW
EXECUTE FUNCTION private.reconcile_negative_stock_replenishment();

CREATE FUNCTION private.trg_g4_guard_negative_sale_movement()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
    IF NEW.balance_after_base_qty<0 AND NOT EXISTS(
        SELECT 1 FROM public.pos_negative_stock_authorizations authz
        WHERE authz.company_id=NEW.company_id
          AND authz.sales_id=NEW.reference_id
          AND authz.stock_product_id=NEW.product_id
          AND authz.warehouse_id=NEW.warehouse_id
          AND authz.balance_after_base_qty=NEW.balance_after_base_qty
    ) THEN RAISE EXCEPTION 'NEGATIVE_STOCK_AUTHORIZATION_REQUIRED'; END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER g4_guard_negative_sale_movement
BEFORE INSERT ON public.stock_movements FOR EACH ROW
WHEN (NEW.balance_after_base_qty<0)
EXECUTE FUNCTION private.trg_g4_guard_negative_sale_movement();

DO $patch_sale$
DECLARE v_definition TEXT; v_patched TEXT;
    v_old TEXT; v_new TEXT;
BEGIN
    SELECT pg_get_functiondef(
        'private.post_pos_sale_online_core(uuid,bigint,uuid)'::regprocedure
    ) INTO v_definition;
    v_patched:=replace(v_definition,
        'v_shortages JSONB := ''[]''::JSONB;',
        'v_shortages JSONB := ''[]''::JSONB;
    v_negative_authorization_id UUID;
    v_negative_cost NUMERIC(20,4);');
    IF v_patched=v_definition THEN
        RAISE EXCEPTION 'SALE_PATCH_FAILED: declarations'; END IF;

    v_patched:=replace(v_patched,
        '''availableBaseQty'',least(v_stock,v_fifo),',
        '''availableBaseQty'',greatest(least(v_stock,v_fifo),0),');
    v_patched:=replace(v_patched,
        'v_requirement.quantity_base - least(v_stock,v_fifo),0',
        'v_requirement.quantity_base - greatest(least(v_stock,v_fifo),0),0');

    v_patched:=replace(v_patched,
        'IF jsonb_array_length(v_shortages) > 0 THEN',
        'IF jsonb_array_length(v_shortages) > 0 AND NOT
       private.authorize_pos_negative_stock(
           v_company,v_sale.id,v_sale.sales_warehouse_id,v_actor,
           v_shortages,v_sale.payload_snapshot->>''negativeStockReason''
       ) THEN');

    v_old:='IF v_remaining > 0 THEN RAISE EXCEPTION ''FIFO_STOCK_CHANGED''; END IF;';
    v_new:='IF v_remaining > 0 THEN
            SELECT authz.id,authz.provisional_unit_cost
            INTO v_negative_authorization_id,v_negative_cost
            FROM public.pos_negative_stock_authorizations authz
            WHERE authz.company_id=v_company AND authz.sales_id=v_sale.id
              AND authz.stock_product_id=v_requirement.stock_product_id;
            IF NOT FOUND THEN RAISE EXCEPTION ''FIFO_STOCK_CHANGED''; END IF;
            INSERT INTO public.negative_stock_sale_allocations(
                company_id,authorization_id,sales_id,sales_detail_id,
                stock_requirement_id,stock_product_id,warehouse_id,
                shortage_base_qty,provisional_unit_cost,provisional_cost_total
            ) VALUES(
                v_company,v_negative_authorization_id,v_sale.id,
                v_requirement.sales_detail_id,v_requirement.id,
                v_requirement.stock_product_id,v_sale.sales_warehouse_id,
                v_remaining,v_negative_cost,round(v_remaining*v_negative_cost,4)
            );
            v_requirement_cost:=v_requirement_cost
                +round(v_remaining*v_negative_cost,4);
            v_remaining:=0;
        END IF;';
    IF position(v_old IN v_patched)=0 THEN
        RAISE EXCEPTION 'SALE_PATCH_FAILED: FIFO guard'; END IF;
    v_patched:=replace(v_patched,v_old,v_new);

    v_old:='UPDATE public.product_stocks
        SET stock_qty = stock_qty - v_requirement.quantity_base,
            updated_at = clock_timestamp()
        WHERE company_id = v_company
          AND product_id = v_requirement.stock_product_id
          AND warehouse_id = v_sale.sales_warehouse_id
          AND stock_qty >= v_requirement.quantity_base
        RETURNING stock_qty INTO v_stock_after;
        IF NOT FOUND THEN RAISE EXCEPTION ''STOCK_CHANGED_DURING_POST''; END IF;';
    v_new:='INSERT INTO public.product_stocks(
            product_id,warehouse_id,stock_qty,company_id
        ) VALUES(
            v_requirement.stock_product_id,v_sale.sales_warehouse_id,
            -v_requirement.quantity_base,v_company
        ) ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
            stock_qty=public.product_stocks.stock_qty
                -v_requirement.quantity_base,
            updated_at=clock_timestamp()
        RETURNING stock_qty INTO v_stock_after;';
    IF position(v_old IN v_patched)=0 THEN
        RAISE EXCEPTION 'SALE_PATCH_FAILED: stock mutation'; END IF;
    v_patched:=replace(v_patched,v_old,v_new);
    IF v_patched!~'pos_negative_stock_authorizations'
       OR v_patched!~'negative_stock_sale_allocations'
       OR v_patched!~'authorize_pos_negative_stock' THEN
        RAISE EXCEPTION 'SALE_PATCH_FAILED: markers';
    END IF;
    EXECUTE v_patched;
END
$patch_sale$;

REVOKE ALL ON FUNCTION
    private.resolve_pos_negative_stock_provisional_cost(UUID,UUID,UUID),
    private.authorize_pos_negative_stock(UUID,UUID,UUID,UUID,JSONB,TEXT),
    private.reconcile_negative_stock_replenishment(),
    private.trg_g4_guard_negative_sale_movement()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.resolve_pos_negative_stock_provisional_cost(UUID,UUID,UUID),
    private.authorize_pos_negative_stock(UUID,UUID,UUID,UUID,JSONB,TEXT),
    private.reconcile_negative_stock_replenishment(),
    private.trg_g4_guard_negative_sale_movement()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260805220000','g4_phase60_negative_stock_online_runtime',
    'STK-006 atomic online non-Bundle authorization, provisional HPP, negative Sale Movement, outstanding allocation and automatic incoming-batch reconciliation; default OFF');
COMMIT;
