-- G4 phase 58: negative-stock entitlement, policy, Warehouse opt-in, and actor permission.
-- Runtime Sale shortage bypass remains closed until the allocation phase.
BEGIN;

DO $guard$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260805160000') THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: phase56';
    END IF;
    IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260805190000') THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260805190000';
    END IF;
    IF EXISTS(SELECT 1 FROM public.product_stocks WHERE stock_qty<0)
       OR EXISTS(SELECT 1 FROM public.product_batches
                 WHERE qty_purchased<0 OR qty_remaining<0) THEN
        RAISE EXCEPTION 'G4_PHASE58_STATE_CHANGED: negative inventory exists';
    END IF;
END
$guard$;

INSERT INTO public.platform_features(
    feature_code,feature_name,module_code,description
) VALUES(
    'pos_negative_stock_enabled','POS Negative Stock','POS',
    'Controlled online-only POS negative-stock exception; default disabled.'
) ON CONFLICT(feature_code) DO UPDATE SET
    feature_name=excluded.feature_name,module_code=excluded.module_code,
    description=excluded.description,updated_at=clock_timestamp();

CREATE TABLE public.pos_negative_stock_policies(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    is_active BOOLEAN NOT NULL DEFAULT FALSE,
    require_reason BOOLEAN NOT NULL DEFAULT TRUE,
    company_negative_limit_base_qty NUMERIC(24,6),
    provisional_cost_method TEXT NOT NULL DEFAULT 'LAST_FIFO_OR_PRODUCT_COGS',
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID REFERENCES public.profiles(id),
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT pos_negative_stock_policies_company_unique UNIQUE(company_id),
    CONSTRAINT pos_negative_stock_policies_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT pos_negative_stock_policies_limit_positive CHECK(
        company_negative_limit_base_qty IS NULL
        OR company_negative_limit_base_qty>0
    ),
    CONSTRAINT pos_negative_stock_policies_cost_method_check CHECK(
        provisional_cost_method='LAST_FIFO_OR_PRODUCT_COGS'
    ),
    CONSTRAINT pos_negative_stock_policies_version_positive
        CHECK(master_version>0)
);

CREATE TABLE public.pos_negative_stock_permissions(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    warehouse_id UUID NOT NULL,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    max_negative_base_qty NUMERIC(24,6),
    valid_until TIMESTAMPTZ,
    grant_reason TEXT NOT NULL,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID REFERENCES public.profiles(id),
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT pos_negative_stock_permissions_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT pos_negative_stock_permissions_scope_unique
        UNIQUE(company_id,warehouse_id,user_id),
    CONSTRAINT fk_pos_negative_stock_permission_warehouse
        FOREIGN KEY(company_id,warehouse_id)
        REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT pos_negative_stock_permissions_limit_positive CHECK(
        max_negative_base_qty IS NULL OR max_negative_base_qty>0
    ),
    CONSTRAINT pos_negative_stock_permissions_reason_not_blank
        CHECK(btrim(grant_reason)<>''),
    CONSTRAINT pos_negative_stock_permissions_version_positive
        CHECK(master_version>0)
);

CREATE TABLE public.pos_negative_stock_authorizations(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    sales_id UUID NOT NULL,
    sales_detail_id UUID NOT NULL,
    stock_product_id UUID NOT NULL,
    warehouse_id UUID NOT NULL,
    permission_id UUID NOT NULL,
    actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    reason TEXT NOT NULL,
    requested_base_qty NUMERIC(24,6) NOT NULL,
    available_base_qty NUMERIC(24,6) NOT NULL,
    shortage_base_qty NUMERIC(24,6) NOT NULL,
    balance_after_base_qty NUMERIC(24,6) NOT NULL,
    provisional_unit_cost NUMERIC(20,4) NOT NULL,
    policy_version BIGINT NOT NULL,
    permission_version BIGINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT pos_negative_stock_authorizations_source_unique
        UNIQUE(company_id,sales_id,stock_product_id),
    CONSTRAINT pos_negative_stock_authorizations_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT fk_pos_negative_stock_authorization_sale
        FOREIGN KEY(company_id,sales_id)
        REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_pos_negative_stock_authorization_detail
        FOREIGN KEY(company_id,sales_detail_id)
        REFERENCES public.sales_details(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_pos_negative_stock_authorization_product
        FOREIGN KEY(company_id,stock_product_id)
        REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_pos_negative_stock_authorization_warehouse
        FOREIGN KEY(company_id,warehouse_id)
        REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_pos_negative_stock_authorization_permission
        FOREIGN KEY(company_id,permission_id)
        REFERENCES public.pos_negative_stock_permissions(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT pos_negative_stock_authorizations_shape CHECK(
        btrim(reason)<>'' AND requested_base_qty>0
        AND available_base_qty>=0 AND shortage_base_qty>0
        AND balance_after_base_qty<0 AND provisional_unit_cost>=0
        AND policy_version>0 AND permission_version>0
    )
);

CREATE TABLE public.negative_stock_sale_allocations(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    authorization_id UUID NOT NULL,
    sales_id UUID NOT NULL,
    sales_detail_id UUID NOT NULL,
    stock_requirement_id UUID NOT NULL,
    stock_product_id UUID NOT NULL,
    warehouse_id UUID NOT NULL,
    shortage_base_qty NUMERIC(24,6) NOT NULL,
    replenished_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,
    provisional_unit_cost NUMERIC(20,4) NOT NULL,
    provisional_cost_total NUMERIC(20,4) NOT NULL,
    actual_cost_total NUMERIC(20,4) NOT NULL DEFAULT 0,
    cost_variance_total NUMERIC(20,4) NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    reconciled_at TIMESTAMPTZ,
    CONSTRAINT negative_stock_sale_allocations_requirement_unique
        UNIQUE(company_id,stock_requirement_id),
    CONSTRAINT negative_stock_sale_allocations_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT fk_negative_sale_allocation_authorization
        FOREIGN KEY(company_id,authorization_id)
        REFERENCES public.pos_negative_stock_authorizations(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_negative_sale_allocation_requirement
        FOREIGN KEY(company_id,stock_requirement_id)
        REFERENCES public.sale_stock_requirements(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT negative_stock_sale_allocations_shape CHECK(
        shortage_base_qty>0 AND replenished_base_qty>=0
        AND replenished_base_qty<=shortage_base_qty
        AND provisional_unit_cost>=0 AND provisional_cost_total>=0
        AND actual_cost_total>=0
        AND ((replenished_base_qty=shortage_base_qty
              AND reconciled_at IS NOT NULL)
             OR (replenished_base_qty<shortage_base_qty
                 AND reconciled_at IS NULL))
    )
);

CREATE TABLE public.negative_stock_replenishment_allocations(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    negative_sale_allocation_id UUID NOT NULL,
    product_batch_id UUID NOT NULL,
    replenished_base_qty NUMERIC(24,6) NOT NULL,
    provisional_unit_cost NUMERIC(20,4) NOT NULL,
    actual_unit_cost NUMERIC(20,4) NOT NULL,
    cost_variance_total NUMERIC(20,4) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT negative_stock_replenishment_source_unique
        UNIQUE(company_id,negative_sale_allocation_id,product_batch_id),
    CONSTRAINT fk_negative_replenishment_sale_allocation
        FOREIGN KEY(company_id,negative_sale_allocation_id)
        REFERENCES public.negative_stock_sale_allocations(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_negative_replenishment_batch
        FOREIGN KEY(product_batch_id)
        REFERENCES public.product_batches(id) ON DELETE RESTRICT,
    CONSTRAINT negative_stock_replenishment_shape CHECK(
        replenished_base_qty>0 AND provisional_unit_cost>=0
        AND actual_unit_cost>=0
    )
);

CREATE TABLE public.pos_negative_stock_configuration_audit(
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    object_type TEXT NOT NULL CHECK(object_type IN('POLICY','WAREHOUSE','PERMISSION')),
    object_id UUID NOT NULL,
    actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_negative_stock_permissions_actor
    ON public.pos_negative_stock_permissions(company_id,user_id,is_active);
CREATE INDEX idx_negative_stock_authorizations_sale
    ON public.pos_negative_stock_authorizations(company_id,sales_id);
CREATE INDEX idx_negative_stock_allocations_open
    ON public.negative_stock_sale_allocations(
        company_id,stock_product_id,warehouse_id,created_at
    ) WHERE reconciled_at IS NULL;

ALTER TABLE public.warehouses
    DROP CONSTRAINT warehouses_nonnegative_only_check;

INSERT INTO public.pos_negative_stock_policies(company_id)
SELECT company.id FROM public.companies company
ON CONFLICT(company_id) DO NOTHING;

CREATE FUNCTION private.trg_g4_provision_negative_stock_policy()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
    INSERT INTO public.pos_negative_stock_policies(company_id)
    VALUES(NEW.id) ON CONFLICT(company_id) DO NOTHING;
    RETURN NEW;
END;
$$;
CREATE TRIGGER g4_provision_negative_stock_policy
AFTER INSERT ON public.companies FOR EACH ROW
EXECUTE FUNCTION private.trg_g4_provision_negative_stock_policy();

CREATE FUNCTION public.save_pos_negative_stock_policy(
    p_expected_master_version BIGINT,p_is_active BOOLEAN,
    p_require_reason BOOLEAN,p_company_negative_limit_base_qty NUMERIC
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid(); v_company UUID:=public.private_active_company_id();
    v_old public.pos_negative_stock_policies%ROWTYPE;
    v_new public.pos_negative_stock_policies%ROWTYPE;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_role(v_company,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]) THEN
        RAISE EXCEPTION 'NEGATIVE_STOCK_POLICY_FORBIDDEN';
    END IF;
    SELECT * INTO v_old FROM public.pos_negative_stock_policies
    WHERE company_id=v_company FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'NEGATIVE_STOCK_POLICY_NOT_FOUND'; END IF;
    IF p_expected_master_version IS DISTINCT FROM v_old.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    UPDATE public.pos_negative_stock_policies SET
        is_active=COALESCE(p_is_active,FALSE),
        require_reason=COALESCE(p_require_reason,TRUE),
        company_negative_limit_base_qty=p_company_negative_limit_base_qty,
        master_version=master_version+1,updated_by=v_actor,
        updated_at=clock_timestamp()
    WHERE company_id=v_company RETURNING * INTO v_new;
    INSERT INTO public.pos_negative_stock_configuration_audit(
        company_id,object_type,object_id,actor_id,before_state,after_state
    ) VALUES(v_company,'POLICY',v_new.id,v_actor,to_jsonb(v_old),to_jsonb(v_new));
    RETURN jsonb_build_object('policyId',v_new.id,
        'masterVersion',v_new.master_version,'isActive',v_new.is_active);
END;
$$;

CREATE FUNCTION public.set_warehouse_negative_stock_opt_in(
    p_warehouse_id UUID,p_allow BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid(); v_company UUID:=public.private_active_company_id();
    v_old public.warehouses%ROWTYPE; v_new public.warehouses%ROWTYPE;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_role(v_company,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]) THEN
        RAISE EXCEPTION 'NEGATIVE_STOCK_WAREHOUSE_FORBIDDEN';
    END IF;
    SELECT * INTO v_old FROM public.warehouses
    WHERE company_id=v_company AND id=p_warehouse_id FOR UPDATE;
    IF NOT FOUND OR NOT v_old.is_active OR NOT v_old.is_sale_source THEN
        RAISE EXCEPTION 'ACTIVE_SALE_SOURCE_WAREHOUSE_REQUIRED';
    END IF;
    UPDATE public.warehouses SET allow_negative_stock=COALESCE(p_allow,FALSE),
        updated_by=v_actor WHERE company_id=v_company AND id=p_warehouse_id
    RETURNING * INTO v_new;
    INSERT INTO public.pos_negative_stock_configuration_audit(
        company_id,object_type,object_id,actor_id,before_state,after_state
    ) VALUES(v_company,'WAREHOUSE',v_new.id,v_actor,to_jsonb(v_old),to_jsonb(v_new));
    RETURN jsonb_build_object('warehouseId',v_new.id,
        'allowNegativeStock',v_new.allow_negative_stock);
END;
$$;

CREATE FUNCTION public.save_pos_negative_stock_permission(
    p_permission_id UUID,p_expected_master_version BIGINT,p_warehouse_id UUID,
    p_user_id UUID,p_max_negative_base_qty NUMERIC,p_valid_until TIMESTAMPTZ,
    p_grant_reason TEXT,p_is_active BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid(); v_company UUID:=public.private_active_company_id();
    v_old public.pos_negative_stock_permissions%ROWTYPE;
    v_new public.pos_negative_stock_permissions%ROWTYPE;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_role(v_company,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]) THEN
        RAISE EXCEPTION 'NEGATIVE_STOCK_PERMISSION_FORBIDDEN';
    END IF;
    IF NULLIF(btrim(p_grant_reason),'') IS NULL THEN
        RAISE EXCEPTION 'NEGATIVE_STOCK_GRANT_REASON_REQUIRED';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM public.warehouses warehouse
        WHERE warehouse.company_id=v_company AND warehouse.id=p_warehouse_id
          AND warehouse.is_active AND warehouse.is_sale_source) THEN
        RAISE EXCEPTION 'ACTIVE_SALE_SOURCE_WAREHOUSE_REQUIRED';
    END IF;
    IF NOT public.private_is_super_admin(p_user_id)
       AND NOT EXISTS(SELECT 1 FROM public.company_memberships membership
            WHERE membership.company_id=v_company AND membership.user_id=p_user_id
              AND membership.status='ACTIVE')
       AND NOT EXISTS(SELECT 1 FROM public.store_memberships membership
            WHERE membership.company_id=v_company AND membership.user_id=p_user_id
              AND membership.status='ACTIVE') THEN
        RAISE EXCEPTION 'ACTIVE_COMPANY_USER_REQUIRED';
    END IF;
    IF p_permission_id IS NULL THEN
        INSERT INTO public.pos_negative_stock_permissions(
            company_id,warehouse_id,user_id,is_active,max_negative_base_qty,
            valid_until,grant_reason,created_by,updated_by
        ) VALUES(v_company,p_warehouse_id,p_user_id,COALESCE(p_is_active,TRUE),
            p_max_negative_base_qty,p_valid_until,btrim(p_grant_reason),v_actor,v_actor)
        RETURNING * INTO v_new;
        INSERT INTO public.pos_negative_stock_configuration_audit(
            company_id,object_type,object_id,actor_id,after_state
        ) VALUES(v_company,'PERMISSION',v_new.id,v_actor,to_jsonb(v_new));
    ELSE
        SELECT * INTO v_old FROM public.pos_negative_stock_permissions
        WHERE company_id=v_company AND id=p_permission_id FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'NEGATIVE_STOCK_PERMISSION_NOT_FOUND'; END IF;
        IF p_expected_master_version IS DISTINCT FROM v_old.master_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        UPDATE public.pos_negative_stock_permissions SET
            warehouse_id=p_warehouse_id,user_id=p_user_id,
            is_active=COALESCE(p_is_active,FALSE),
            max_negative_base_qty=p_max_negative_base_qty,
            valid_until=p_valid_until,grant_reason=btrim(p_grant_reason),
            master_version=master_version+1,updated_by=v_actor,
            updated_at=clock_timestamp()
        WHERE company_id=v_company AND id=p_permission_id RETURNING * INTO v_new;
        INSERT INTO public.pos_negative_stock_configuration_audit(
            company_id,object_type,object_id,actor_id,before_state,after_state
        ) VALUES(v_company,'PERMISSION',v_new.id,v_actor,to_jsonb(v_old),to_jsonb(v_new));
    END IF;
    RETURN jsonb_build_object('permissionId',v_new.id,
        'masterVersion',v_new.master_version,'isActive',v_new.is_active);
END;
$$;

ALTER TABLE public.pos_negative_stock_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_negative_stock_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_negative_stock_authorizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.negative_stock_sale_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.negative_stock_replenishment_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_negative_stock_configuration_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Negative stock policy readable in active Company"
ON public.pos_negative_stock_policies FOR SELECT TO authenticated
USING(public.private_request_company_matches(company_id)
      AND public.private_user_has_company_access(company_id));
CREATE POLICY "Negative stock permission readable by managers"
ON public.pos_negative_stock_permissions FOR SELECT TO authenticated
USING(public.private_request_company_matches(company_id)
      AND public.private_user_has_any_company_or_store_role(company_id,
          ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER']::TEXT[]));
CREATE POLICY "Negative stock history readable in active Company"
ON public.pos_negative_stock_authorizations FOR SELECT TO authenticated
USING(public.private_request_company_matches(company_id)
      AND public.private_user_has_company_access(company_id));
CREATE POLICY "Negative allocation readable in active Company"
ON public.negative_stock_sale_allocations FOR SELECT TO authenticated
USING(public.private_request_company_matches(company_id)
      AND public.private_user_has_company_access(company_id));
CREATE POLICY "Negative replenishment readable in active Company"
ON public.negative_stock_replenishment_allocations FOR SELECT TO authenticated
USING(public.private_request_company_matches(company_id)
      AND public.private_user_has_company_access(company_id));
CREATE POLICY "Negative configuration audit readable by managers"
ON public.pos_negative_stock_configuration_audit FOR SELECT TO authenticated
USING(public.private_request_company_matches(company_id)
      AND public.private_user_has_any_company_role(company_id,
          ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]));

REVOKE ALL ON public.pos_negative_stock_policies,
    public.pos_negative_stock_permissions,
    public.pos_negative_stock_authorizations,
    public.negative_stock_sale_allocations,
    public.negative_stock_replenishment_allocations,
    public.pos_negative_stock_configuration_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.pos_negative_stock_policies,
    public.pos_negative_stock_permissions,
    public.pos_negative_stock_authorizations,
    public.negative_stock_sale_allocations,
    public.negative_stock_replenishment_allocations,
    public.pos_negative_stock_configuration_audit TO authenticated;
GRANT ALL ON public.pos_negative_stock_policies,
    public.pos_negative_stock_permissions,
    public.pos_negative_stock_authorizations,
    public.negative_stock_sale_allocations,
    public.negative_stock_replenishment_allocations,
    public.pos_negative_stock_configuration_audit TO service_role;
REVOKE UPDATE ON public.warehouses FROM authenticated;
REVOKE ALL ON FUNCTION
    public.save_pos_negative_stock_policy(BIGINT,BOOLEAN,BOOLEAN,NUMERIC),
    public.set_warehouse_negative_stock_opt_in(UUID,BOOLEAN),
    public.save_pos_negative_stock_permission(UUID,BIGINT,UUID,UUID,NUMERIC,TIMESTAMPTZ,TEXT,BOOLEAN)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION private.trg_g4_provision_negative_stock_policy()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    public.save_pos_negative_stock_policy(BIGINT,BOOLEAN,BOOLEAN,NUMERIC),
    public.set_warehouse_negative_stock_opt_in(UUID,BOOLEAN),
    public.save_pos_negative_stock_permission(UUID,BIGINT,UUID,UUID,NUMERIC,TIMESTAMPTZ,TEXT,BOOLEAN)
TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION private.trg_g4_provision_negative_stock_policy()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260805190000','g4_phase58_negative_stock_policy_foundation',
    'STK-006 default-OFF entitlement, policy, Warehouse opt-in, actor permission, immutable allocation schema and audit; Sale runtime remains fail-closed');
COMMIT;
