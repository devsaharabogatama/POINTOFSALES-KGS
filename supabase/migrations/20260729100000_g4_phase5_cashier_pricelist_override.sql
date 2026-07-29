-- KGS POS G4 phase 5: server-authoritative Cashier Pricelist selection.
-- AUTO preserves the approved Customer -> Global -> Product-UOM resolver.
-- Explicit selection may use an eligible Global Pricelist or the selected
-- Customer's own assigned reusable Pricelist. Cross-Customer overrides fail.

BEGIN;

DO $guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260729090000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Store Manager POS access fix missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260729100000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260729100000';
    END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION private.resolve_pos_sale_price(
    p_company_id UUID,
    p_store_id UUID,
    p_customer_id UUID,
    p_product_uom_id UUID,
    p_quantity NUMERIC,
    p_resolved_at TIMESTAMPTZ
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_product_id UUID;
    v_factor NUMERIC(24,6);
    v_base_price NUMERIC(20,4);
    v_product_name TEXT;
    v_uom_name TEXT;
    v_rule RECORD;
    v_resolved NUMERIC(20,4);
    v_selected_raw TEXT :=
        NULLIF(current_setting('kgs.selected_pricelist_id',TRUE),'');
    v_selected_pricelist_id UUID;
    v_selection_source TEXT := 'AUTO';
BEGIN
    IF p_company_id IS NULL OR p_store_id IS NULL
       OR p_product_uom_id IS NULL OR p_resolved_at IS NULL THEN
        RAISE EXCEPTION 'PRICE_RESOLVER_CONTEXT_REQUIRED';
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'SALE_QUANTITY_INVALID';
    END IF;
    BEGIN
        v_selected_pricelist_id := v_selected_raw::UUID;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'INVALID_PRICELIST_SELECTION';
    END;
    IF v_selected_pricelist_id IS NOT NULL THEN
        v_selection_source := 'CASHIER_OVERRIDE';
    END IF;

    SELECT
        pu.product_id,pu.factor_to_base,pu.sale_price,p.name,u.name
    INTO
        v_product_id,v_factor,v_base_price,v_product_name,v_uom_name
    FROM public.product_uoms pu
    JOIN public.products p
      ON p.company_id = pu.company_id
     AND p.id = pu.product_id
     AND p.is_active
    JOIN public.uoms u
      ON u.company_id = pu.company_id
     AND u.id = pu.uom_id
     AND u.is_active
    WHERE pu.company_id = p_company_id
      AND pu.id = p_product_uom_id
      AND pu.is_active
      AND pu.sales_allowed
      AND pu.sale_price IS NOT NULL
      AND pu.sale_price >= 0;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACTIVE_SALES_PRODUCT_UOM_NOT_FOUND';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.stores s
        WHERE s.company_id = p_company_id
          AND s.id = p_store_id
          AND s.status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'ACTIVE_STORE_NOT_FOUND';
    END IF;
    IF p_customer_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.customers c
        WHERE c.company_id = p_company_id
          AND c.id = p_customer_id
          AND c.is_active
    ) THEN
        RAISE EXCEPTION 'ACTIVE_CUSTOMER_NOT_FOUND';
    END IF;

    IF v_selected_pricelist_id IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM public.pricelists pl
        LEFT JOIN public.customers c
          ON c.company_id = pl.company_id
         AND c.id = p_customer_id
        WHERE pl.company_id = p_company_id
          AND pl.id = v_selected_pricelist_id
          AND pl.is_active
          AND (pl.valid_from IS NULL OR pl.valid_from <= p_resolved_at)
          AND (pl.valid_until IS NULL OR pl.valid_until >= p_resolved_at)
          AND (
              pl.scope = 'GLOBAL'
              OR (
                  pl.scope = 'CUSTOMER'
                  AND c.default_pricelist_id = pl.id
              )
          )
          AND (
              pl.applies_all_stores
              OR EXISTS (
                  SELECT 1
                  FROM public.pricelist_store_assignments psa
                  WHERE psa.company_id = pl.company_id
                    AND psa.pricelist_id = pl.id
                    AND psa.store_id = p_store_id
              )
          )
    ) THEN
        RAISE EXCEPTION 'PRICELIST_NOT_ELIGIBLE';
    END IF;

    SELECT
        ranked.pricelist_id,
        ranked.pricelist_rule_id,
        ranked.pricelist_name,
        ranked.pricing_method,
        ranked.fixed_unit_price,
        ranked.discount_amount_per_unit,
        ranked.discount_percent,
        ranked.rule_version
    INTO v_rule
    FROM (
        SELECT
            pl.id AS pricelist_id,
            pr.id AS pricelist_rule_id,
            pl.name AS pricelist_name,
            pr.pricing_method,
            pr.fixed_unit_price,
            pr.discount_amount_per_unit,
            pr.discount_percent,
            pr.rule_version,
            CASE WHEN pl.scope = 'CUSTOMER' THEN 1 ELSE 2 END AS source_rank,
            pl.priority,
            pr.min_qty
        FROM public.pricelists pl
        JOIN public.pricelist_rules pr
          ON pr.company_id = pl.company_id
         AND pr.pricelist_id = pl.id
         AND pr.product_id = v_product_id
         AND pr.product_uom_id = p_product_uom_id
         AND pr.is_active
         AND (pr.valid_from IS NULL OR pr.valid_from <= p_resolved_at)
         AND (pr.valid_until IS NULL OR pr.valid_until >= p_resolved_at)
         AND pr.min_qty <= CASE
             WHEN pr.tier_qty_basis = 'BASE_UOM_EQUIVALENT'
                 THEN p_quantity * v_factor
             ELSE p_quantity
         END
        LEFT JOIN public.customers c
          ON c.company_id = pl.company_id
         AND c.id = p_customer_id
        WHERE pl.company_id = p_company_id
          AND pl.is_active
          AND (pl.valid_from IS NULL OR pl.valid_from <= p_resolved_at)
          AND (pl.valid_until IS NULL OR pl.valid_until >= p_resolved_at)
          AND (
              (
                  v_selected_pricelist_id IS NULL
                  AND (
                      (
                          pl.scope = 'CUSTOMER'
                          AND c.default_pricelist_id = pl.id
                      )
                      OR (pl.scope = 'GLOBAL' AND pl.is_default)
                  )
              )
              OR pl.id = v_selected_pricelist_id
          )
          AND (
              pl.applies_all_stores
              OR EXISTS (
                  SELECT 1
                  FROM public.pricelist_store_assignments psa
                  WHERE psa.company_id = pl.company_id
                    AND psa.pricelist_id = pl.id
                    AND psa.store_id = p_store_id
              )
          )
        ORDER BY
            source_rank,
            priority DESC,
            min_qty DESC,
            pr.id
        LIMIT 1
    ) ranked;

    IF v_rule.pricelist_rule_id IS NULL THEN
        v_resolved := v_base_price;
    ELSIF v_rule.pricing_method = 'FIXED_PRICE' THEN
        v_resolved := v_rule.fixed_unit_price;
    ELSIF v_rule.pricing_method = 'DISCOUNT_AMOUNT' THEN
        v_resolved := greatest(
            v_base_price - v_rule.discount_amount_per_unit,0
        );
    ELSE
        v_resolved := round(
            v_base_price * (100 - v_rule.discount_percent) / 100,4
        );
    END IF;

    RETURN jsonb_build_object(
        'productId',v_product_id,
        'productName',v_product_name,
        'productUomId',p_product_uom_id,
        'uomName',v_uom_name,
        'factorToBase',v_factor,
        'baseUnitPrice',v_base_price,
        'resolvedUnitPrice',v_resolved,
        'pricelistId',v_rule.pricelist_id,
        'pricelistRuleId',v_rule.pricelist_rule_id,
        'pricelistName',v_rule.pricelist_name,
        'ruleVersion',v_rule.rule_version,
        'pricingSelectionSource',v_selection_source,
        'resolvedAt',p_resolved_at
    );
END;
$$;

CREATE FUNCTION public.save_pos_sale_draft_with_pricelist(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM set_config(
        'kgs.selected_pricelist_id',
        COALESCE(NULLIF(p_payload->>'selectedPricelistId',''),''),
        TRUE
    );
    RETURN public.save_pos_sale_draft(p_payload);
END;
$$;

CREATE FUNCTION public.post_pos_sale_with_pricelist(
    p_sales_id UUID,
    p_master_version BIGINT,
    p_posting_idempotency_key UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_selected_pricelist_id TEXT;
BEGIN
    SELECT NULLIF(sh.payload_snapshot->>'selectedPricelistId','')
    INTO v_selected_pricelist_id
    FROM public.sales_headers sh
    WHERE sh.company_id = public.private_active_company_id()
      AND sh.id = p_sales_id;

    PERFORM set_config(
        'kgs.selected_pricelist_id',
        COALESCE(v_selected_pricelist_id,''),
        TRUE
    );
    RETURN public.post_pos_sale(
        p_sales_id,p_master_version,p_posting_idempotency_key
    );
END;
$$;

REVOKE ALL ON FUNCTION private.resolve_pos_sale_price(
    UUID,UUID,UUID,UUID,NUMERIC,TIMESTAMPTZ
) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.resolve_pos_sale_price(
    UUID,UUID,UUID,UUID,NUMERIC,TIMESTAMPTZ
) TO service_role;

REVOKE ALL ON FUNCTION public.save_pos_sale_draft_with_pricelist(JSONB)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.post_pos_sale_with_pricelist(UUID,BIGINT,UUID)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_pos_sale_draft_with_pricelist(JSONB)
TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.post_pos_sale_with_pricelist(
    UUID,BIGINT,UUID
) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260729100000',
    'g4_phase5_cashier_pricelist_override',
    'Adds server-authoritative AUTO/Cashier override Pricelist selection while preserving Customer-exclusive and Store eligibility boundaries'
);

COMMIT;
