-- G4 phase 14: authoritative Offline catalog snapshot for one open Session.
-- Additive only. Does not enable Offline POS or create Terminal eligibility.

BEGIN;

DO $guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260729210000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G4 Phase 12 required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260730010000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260730010000';
    END IF;
    IF to_regprocedure(
        'public.get_pos_offline_catalog_snapshot(uuid)'
    ) IS NOT NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: snapshot RPC already exists';
    END IF;
END
$guard$;

CREATE FUNCTION public.get_pos_offline_catalog_snapshot(
    p_cashier_session_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_session public.cashier_sessions%ROWTYPE;
    v_snapshot_at TIMESTAMPTZ := statement_timestamp();
    v_catalog_version BIGINT;
    v_result JSONB;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.company_features cf
        WHERE cf.company_id = v_company
          AND cf.feature_code = 'offline_pos_enabled'
          AND cf.is_enabled
    ) THEN
        RAISE EXCEPTION 'OFFLINE_POS_FEATURE_DISABLED';
    END IF;

    SELECT * INTO v_session
    FROM public.cashier_sessions cs
    WHERE cs.company_id = v_company
      AND cs.id = p_cashier_session_id
      AND cs.cashier_id = v_actor
      AND cs.status = 'OPEN'::public.session_status;
    IF NOT FOUND THEN RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED'; END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.pos_offline_allowance_policies p
        WHERE p.company_id = v_company
          AND p.scope_type = 'TERMINAL'
          AND p.store_id = v_session.store_id
          AND p.terminal_id = v_session.pos_id
          AND p.is_enabled
    ) THEN
        RAISE EXCEPTION 'OFFLINE_TERMINAL_NOT_ENABLED';
    END IF;

    v_catalog_version := greatest(
        1,
        floor(extract(epoch FROM v_snapshot_at) * 1000)::BIGINT
    );

    SELECT jsonb_build_object(
        'payloadVersion',1,
        'catalogVersion',v_catalog_version,
        'snapshotAt',v_snapshot_at,
        'companyId',v_company,
        'storeId',v_session.store_id,
        'terminalId',v_session.pos_id,
        'warehouseId',v_session.sales_warehouse_id,
        'cashierSessionId',v_session.id,
        'cashierId',v_actor,
        'customers',(
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'id',c.id,
                'name',c.name,
                'isWalkIn',c.is_system_customer,
                'defaultPricelistId',c.default_pricelist_id,
                'masterVersion',c.master_version
            ) ORDER BY c.is_system_customer DESC,c.name,c.id),'[]'::JSONB)
            FROM public.customers c
            WHERE c.company_id = v_company AND c.is_active
        ),
        'pricelists',(
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'id',pl.id,
                'name',pl.name,
                'scope',pl.scope,
                'isDefault',pl.is_default,
                'priority',pl.priority,
                'validFrom',pl.valid_from,
                'validUntil',pl.valid_until,
                'masterVersion',pl.master_version
            ) ORDER BY
                CASE WHEN pl.scope = 'CUSTOMER' THEN 1 ELSE 2 END,
                pl.priority DESC,pl.name,pl.id
            ),'[]'::JSONB)
            FROM public.pricelists pl
            WHERE pl.company_id = v_company
              AND pl.is_active
              AND (pl.valid_from IS NULL OR pl.valid_from <= v_snapshot_at)
              AND (pl.valid_until IS NULL OR pl.valid_until >= v_snapshot_at)
              AND (
                  pl.applies_all_stores
                  OR EXISTS (
                      SELECT 1
                      FROM public.pricelist_store_assignments psa
                      WHERE psa.company_id = pl.company_id
                        AND psa.pricelist_id = pl.id
                        AND psa.store_id = v_session.store_id
                  )
              )
        ),
        'pricelistRules',(
            SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(
                jsonb_build_object(
                    'id',pr.id,
                    'pricelistId',pr.pricelist_id,
                    'productId',pr.product_id,
                    'productUomId',pr.product_uom_id,
                    'minQty',pr.min_qty,
                    'tierQtyBasis',pr.tier_qty_basis,
                    'pricingMethod',pr.pricing_method,
                    'fixedUnitPrice',pr.fixed_unit_price,
                    'discountAmountPerUnit',
                        pr.discount_amount_per_unit,
                    'discountPercent',pr.discount_percent,
                    'validFrom',pr.valid_from,
                    'validUntil',pr.valid_until,
                    'ruleVersion',pr.rule_version,
                    'masterVersion',pr.master_version
                )
            ) ORDER BY pr.product_uom_id,pr.min_qty DESC,pr.id),'[]'::JSONB)
            FROM public.pricelist_rules pr
            JOIN public.pricelists pl
              ON pl.company_id = pr.company_id
             AND pl.id = pr.pricelist_id
            WHERE pr.company_id = v_company
              AND pr.is_active
              AND (pr.valid_from IS NULL OR pr.valid_from <= v_snapshot_at)
              AND (pr.valid_until IS NULL OR pr.valid_until >= v_snapshot_at)
              AND pl.is_active
              AND (pl.valid_from IS NULL OR pl.valid_from <= v_snapshot_at)
              AND (pl.valid_until IS NULL OR pl.valid_until >= v_snapshot_at)
              AND (
                  pl.applies_all_stores
                  OR EXISTS (
                      SELECT 1
                      FROM public.pricelist_store_assignments psa
                      WHERE psa.company_id = pl.company_id
                        AND psa.pricelist_id = pl.id
                        AND psa.store_id = v_session.store_id
                  )
              )
        ),
        'productUoms',(
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'productId',p.id,
                'productUomId',pu.id,
                'sku',p.sku,
                'name',p.name,
                'categoryName',COALESCE(pc.category_name,'Tanpa kategori'),
                'uomId',u.id,
                'uomName',u.name,
                'factorToBase',pu.factor_to_base,
                'baseUnitPrice',pu.sale_price,
                'barcode',pu.barcode,
                'allowDecimal',u.allow_decimal,
                'decimalPrecision',u.decimal_precision,
                'isBundle',p.is_bundle,
                'offlineEligible',NOT p.is_bundle,
                'stockBaseQty',COALESCE(ps.stock_qty,0),
                'productMasterVersion',p.master_version,
                'uomMasterVersion',u.master_version,
                'productUomMasterVersion',pu.master_version,
                'tax',private.resolve_product_tax_rule(
                    v_company,p.id,'SALES',v_snapshot_at
                )
            ) ORDER BY p.name,u.name,pu.id),'[]'::JSONB)
            FROM public.product_uoms pu
            JOIN public.products p
              ON p.company_id = pu.company_id
             AND p.id = pu.product_id
             AND p.is_active
            JOIN public.uoms u
              ON u.company_id = pu.company_id
             AND u.id = pu.uom_id
             AND u.is_active
            LEFT JOIN public.product_categories pc
              ON pc.company_id = p.company_id
             AND pc.id = p.category_id
            LEFT JOIN public.product_stocks ps
              ON ps.company_id = p.company_id
             AND ps.product_id = p.id
             AND ps.warehouse_id = v_session.sales_warehouse_id
            WHERE pu.company_id = v_company
              AND pu.is_active
              AND pu.sales_allowed
              AND pu.sale_price IS NOT NULL
        ),
        'paymentMethods',(
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'id',pm.id,
                'name',pm.payment_method_name,
                'methodType',pm.method_type,
                'proofMode',pm.proof_mode,
                'isDefault',pm.is_default,
                'feeEnabled',pm.fee_enabled,
                'feeBearer',pm.fee_bearer,
                'feeType',pm.fee_type,
                'feePercent',pm.fee_percent,
                'feeFixedAmount',pm.fee_fixed_amount,
                'masterVersion',pm.master_version
            ) ORDER BY pm.is_default DESC,pm.payment_method_name,pm.id),
            '[]'::JSONB)
            FROM public.payment_methods pm
            WHERE pm.company_id = v_company
              AND pm.is_active
              AND pm.method_type NOT IN (
                  'CUSTOMER_BALANCE','KETUL_OFFSET','TEMPO'
              )
              AND (
                  pm.available_all_stores
                  OR EXISTS (
                      SELECT 1
                      FROM public.payment_method_store_assignments pmsa
                      WHERE pmsa.company_id = pm.company_id
                        AND pmsa.payment_method_id = pm.id
                        AND pmsa.store_id = v_session.store_id
                  )
              )
        ),
        'allowances',(
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'id',a.id,
                'productId',a.product_id,
                'baseUomId',a.base_uom_id,
                'allocatedBaseQty',a.allocated_base_qty,
                'consumedBaseQty',a.consumed_base_qty,
                'remainingBaseQty',
                    a.allocated_base_qty - a.consumed_base_qty,
                'masterVersion',a.master_version,
                'createdAt',a.created_at
            ) ORDER BY a.product_id,a.id),'[]'::JSONB)
            FROM public.pos_offline_stock_allowances a
            WHERE a.company_id = v_company
              AND a.cashier_session_id = v_session.id
              AND a.status = 'ACTIVE'
        )
    ) INTO v_result;

    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_pos_offline_catalog_snapshot(UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_pos_offline_catalog_snapshot(UUID)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260730010000',
    'g4_phase14_offline_catalog_snapshot',
    'POS-004 guarded Session/Terminal Offline snapshot for Product-UOM, Pricelist rules, inclusive Sales Tax metadata, Payment Methods, and active allowances; entitlement remains disabled'
);

COMMIT;
