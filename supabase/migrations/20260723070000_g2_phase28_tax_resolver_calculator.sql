-- KGS POS G2 phase 28: private Tax resolver and deterministic calculator.
-- Requirement: FIN-005 (internal Tax Engine boundary).
-- Dependency: guarded Product/Category Tax assignment through 20260723040000.
--
-- IMPORTANT:
-- - this migration does not connect Tax to checkout, Purchase, journal,
--   return/reversal, or official tax reporting;
-- - transaction snapshot columns remain nullable and are not backfilled;
-- - both routines are private/server-only building blocks.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260723040000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 26 Tax assignment is required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260723070000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260723070000';
    END IF;
END
$migration_guard$;

-- Resolves the canonical rule at one explicit posting timestamp.
-- Product override wins over Product Category default. A missing assignment or
-- disabled entitlement is a valid no-tax result; an assigned but unusable rule
-- raises instead of silently falling back or guessing another rule.
CREATE FUNCTION private.resolve_product_tax_rule(
    p_company_id UUID,
    p_product_id UUID,
    p_tax_scope TEXT,
    p_resolved_at TIMESTAMPTZ
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
    v_scope TEXT := upper(btrim(COALESCE(p_tax_scope,'')));
    v_feature_code TEXT;
    v_product_rule_id UUID;
    v_category_rule_id UUID;
    v_rule_id UUID;
    v_version_count BIGINT;
    v_rule RECORD;
BEGIN
    IF p_company_id IS NULL OR p_product_id IS NULL THEN
        RAISE EXCEPTION 'TAX_RESOLVER_ID_REQUIRED';
    END IF;
    IF p_resolved_at IS NULL THEN
        RAISE EXCEPTION 'TAX_RESOLVER_TIMESTAMP_REQUIRED';
    END IF;
    IF v_scope NOT IN ('SALES','PURCHASE') THEN
        RAISE EXCEPTION 'INVALID_TAX_SCOPE';
    END IF;

    SELECT
        CASE WHEN v_scope = 'SALES' THEN p.sales_tax_rule_id
             ELSE p.purchase_tax_rule_id END,
        CASE WHEN v_scope = 'SALES' THEN pc.default_sales_tax_rule_id
             ELSE pc.default_purchase_tax_rule_id END
    INTO v_product_rule_id,v_category_rule_id
    FROM public.products p
    LEFT JOIN public.product_categories pc
      ON pc.company_id = p.company_id
     AND pc.id = p.category_id
    WHERE p.company_id = p_company_id
      AND p.id = p_product_id
      AND p.is_active;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACTIVE_PRODUCT_NOT_FOUND';
    END IF;

    v_feature_code := CASE v_scope
        WHEN 'SALES' THEN 'tax_sales_enabled'
        ELSE 'tax_purchase_enabled'
    END;
    IF NOT public.private_company_feature_enabled(
        p_company_id,v_feature_code
    ) THEN
        RETURN jsonb_build_object(
            'taxApplied',FALSE,
            'taxScope',v_scope,
            'reason','FEATURE_DISABLED',
            'resolvedAt',p_resolved_at
        );
    END IF;

    v_rule_id := COALESCE(v_product_rule_id,v_category_rule_id);
    IF v_rule_id IS NULL THEN
        RETURN jsonb_build_object(
            'taxApplied',FALSE,
            'taxScope',v_scope,
            'reason','NO_ASSIGNMENT',
            'resolvedAt',p_resolved_at
        );
    END IF;

    SELECT count(*) INTO v_version_count
    FROM public.tax_rules r
    JOIN public.tax_rule_versions v
      ON v.company_id = r.company_id
     AND v.tax_rule_id = r.id
    JOIN public.chart_of_accounts a
      ON a.company_id = v.company_id
     AND a.id = v.account_id
    WHERE r.company_id = p_company_id
      AND r.id = v_rule_id
      AND r.tax_scope = v_scope
      AND r.is_active
      AND v.status = 'ACTIVE'
      AND v.effective_from <= p_resolved_at
      AND (v.effective_to IS NULL OR v.effective_to > p_resolved_at)
      AND a.is_active
      AND a.is_postable;

    IF v_version_count <> 1 THEN
        RAISE EXCEPTION 'CURRENT_TAX_RULE_REQUIRED';
    END IF;

    SELECT
        r.tax_code,
        r.tax_name,
        r.tax_scope,
        v.rule_version,
        v.rate_percent,
        v.calculation_scope,
        v.default_price_mode,
        v.account_function_key,
        v.account_id,
        a.account_code,
        a.account_name,
        v.is_recoverable
    INTO v_rule
    FROM public.tax_rules r
    JOIN public.tax_rule_versions v
      ON v.company_id = r.company_id
     AND v.tax_rule_id = r.id
    JOIN public.chart_of_accounts a
      ON a.company_id = v.company_id
     AND a.id = v.account_id
    WHERE r.company_id = p_company_id
      AND r.id = v_rule_id
      AND r.tax_scope = v_scope
      AND r.is_active
      AND v.status = 'ACTIVE'
      AND v.effective_from <= p_resolved_at
      AND (v.effective_to IS NULL OR v.effective_to > p_resolved_at)
      AND a.is_active
      AND a.is_postable;

    IF (v_scope = 'SALES' AND (
            v_rule.default_price_mode <> 'INCLUSIVE'
            OR v_rule.account_function_key <> 'OUTPUT_TAX'
        )) OR (v_scope = 'PURCHASE' AND (
            v_rule.default_price_mode NOT IN ('INCLUSIVE','EXCLUSIVE')
            OR v_rule.account_function_key <> 'INPUT_TAX'
        )) THEN
        RAISE EXCEPTION 'INVALID_TAX_RULE_RUNTIME_CONTRACT';
    END IF;

    RETURN jsonb_build_object(
        'taxApplied',TRUE,
        'taxScope',v_rule.tax_scope,
        'taxRuleId',v_rule_id,
        'assignmentSource',CASE
            WHEN v_product_rule_id IS NOT NULL THEN 'PRODUCT'
            ELSE 'CATEGORY'
        END,
        'ruleVersion',v_rule.rule_version,
        'taxCode',v_rule.tax_code,
        'taxName',v_rule.tax_name,
        'ratePercent',v_rule.rate_percent,
        'calculationScope',v_rule.calculation_scope,
        'priceMode',v_rule.default_price_mode,
        'accountFunctionKey',v_rule.account_function_key,
        'taxAccountId',v_rule.account_id,
        'taxAccountCode',v_rule.account_code,
        'taxAccountName',v_rule.account_name,
        'isRecoverable',v_rule.is_recoverable,
        'resolvedAt',p_resolved_at
    );
END;
$$;

-- Pure deterministic calculator for one Tax Rule group.
-- p_lines format: [{"lineKey":"stable-key","amount":1000}, ...]
-- amount is tax-inclusive gross for INCLUSIVE, or net tax base for EXCLUSIVE.
CREATE FUNCTION private.calculate_tax_group(
    p_lines JSONB,
    p_rate_percent NUMERIC,
    p_tax_scope TEXT,
    p_price_mode TEXT,
    p_calculation_scope TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE
    v_scope TEXT := upper(btrim(COALESCE(p_tax_scope,'')));
    v_price_mode TEXT := upper(btrim(COALESCE(p_price_mode,'')));
    v_calculation_scope TEXT :=
        upper(btrim(COALESCE(p_calculation_scope,'')));
    v_line_count INTEGER;
    v_index INTEGER;
    v_largest_index INTEGER := 1;
    v_line JSONB;
    v_line_key TEXT;
    v_amount NUMERIC;
    v_denominator NUMERIC;
    v_exact_base NUMERIC;
    v_exact_tax NUMERIC;
    v_target_tax NUMERIC := 0;
    v_preliminary_tax_total NUMERIC := 0;
    v_residual NUMERIC := 0;
    v_final_base NUMERIC;
    v_final_tax NUMERIC;
    v_line_rounding NUMERIC;
    v_total_base NUMERIC := 0;
    v_total_tax NUMERIC := 0;
    v_total_rounding NUMERIC := 0;
    v_total_gross NUMERIC := 0;
    v_line_keys TEXT[] := ARRAY[]::TEXT[];
    v_amounts NUMERIC[] := ARRAY[]::NUMERIC[];
    v_exact_bases NUMERIC[] := ARRAY[]::NUMERIC[];
    v_exact_taxes NUMERIC[] := ARRAY[]::NUMERIC[];
    v_final_taxes NUMERIC[] := ARRAY[]::NUMERIC[];
    v_output_lines JSONB := '[]'::JSONB;
BEGIN
    IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'TAX_LINES_ARRAY_REQUIRED';
    END IF;
    v_line_count := jsonb_array_length(p_lines);
    IF v_line_count = 0 THEN RAISE EXCEPTION 'TAX_LINES_REQUIRED'; END IF;
    IF p_rate_percent IS NULL
       OR p_rate_percent < 0 OR p_rate_percent > 100 THEN
        RAISE EXCEPTION 'INVALID_TAX_RATE';
    END IF;
    IF v_scope NOT IN ('SALES','PURCHASE') THEN
        RAISE EXCEPTION 'INVALID_TAX_SCOPE';
    END IF;
    IF v_price_mode NOT IN ('INCLUSIVE','EXCLUSIVE') THEN
        RAISE EXCEPTION 'INVALID_TAX_PRICE_MODE';
    END IF;
    IF v_scope = 'SALES' AND v_price_mode <> 'INCLUSIVE' THEN
        RAISE EXCEPTION 'SALES_TAX_MUST_BE_INCLUSIVE';
    END IF;
    IF v_calculation_scope NOT IN ('PER_LINE','PER_DOCUMENT') THEN
        RAISE EXCEPTION 'INVALID_TAX_CALCULATION_SCOPE';
    END IF;

    v_denominator := 1 + (p_rate_percent / 100);
    FOR v_index IN 1..v_line_count LOOP
        v_line := p_lines->(v_index - 1);
        IF jsonb_typeof(v_line) IS DISTINCT FROM 'object' THEN
            RAISE EXCEPTION 'INVALID_TAX_LINE';
        END IF;
        v_line_key := NULLIF(btrim(v_line->>'lineKey'),'');
        IF v_line_key IS NULL THEN RAISE EXCEPTION 'TAX_LINE_KEY_REQUIRED'; END IF;
        IF NOT (v_line ? 'amount')
           OR jsonb_typeof(v_line->'amount') IS DISTINCT FROM 'number' THEN
            RAISE EXCEPTION 'TAX_LINE_AMOUNT_REQUIRED';
        END IF;
        v_amount := (v_line->>'amount')::NUMERIC;
        IF v_amount < 0 THEN RAISE EXCEPTION 'NEGATIVE_TAX_LINE_AMOUNT'; END IF;
        IF v_line_key = ANY(v_line_keys) THEN
            RAISE EXCEPTION 'DUPLICATE_TAX_LINE_KEY';
        END IF;

        IF v_price_mode = 'INCLUSIVE' THEN
            v_exact_base := v_amount / v_denominator;
            v_exact_tax := v_amount - v_exact_base;
        ELSE
            v_exact_base := v_amount;
            v_exact_tax := v_amount * p_rate_percent / 100;
        END IF;

        v_line_keys := array_append(v_line_keys,v_line_key);
        v_amounts := array_append(v_amounts,v_amount);
        v_exact_bases := array_append(v_exact_bases,v_exact_base);
        v_exact_taxes := array_append(v_exact_taxes,v_exact_tax);
        v_final_taxes := array_append(v_final_taxes,round(v_exact_tax,0));
        v_preliminary_tax_total :=
            v_preliminary_tax_total + round(v_exact_tax,0);
        v_target_tax := v_target_tax + v_exact_tax;

        IF v_index > 1
           AND v_exact_base > v_exact_bases[v_largest_index] THEN
            v_largest_index := v_index;
        END IF;
    END LOOP;

    IF v_calculation_scope = 'PER_DOCUMENT' THEN
        v_target_tax := round(v_target_tax,0);
        v_residual := v_target_tax - v_preliminary_tax_total;
        v_final_taxes[v_largest_index] :=
            v_final_taxes[v_largest_index] + v_residual;
    ELSE
        v_target_tax := v_preliminary_tax_total;
    END IF;

    FOR v_index IN 1..v_line_count LOOP
        v_final_tax := v_final_taxes[v_index];
        IF v_price_mode = 'INCLUSIVE' THEN
            v_final_base := v_amounts[v_index] - v_final_tax;
            v_total_gross := v_total_gross + v_amounts[v_index];
        ELSE
            v_final_base := v_exact_bases[v_index];
            v_total_gross :=
                v_total_gross + v_amounts[v_index] + v_final_tax;
        END IF;
        v_line_rounding := v_final_tax - v_exact_taxes[v_index];
        v_total_base := v_total_base + v_final_base;
        v_total_tax := v_total_tax + v_final_tax;
        v_total_rounding := v_total_rounding + v_line_rounding;

        v_output_lines := v_output_lines || jsonb_build_array(
            jsonb_build_object(
                'lineKey',v_line_keys[v_index],
                'inputAmount',round(v_amounts[v_index],4),
                'taxBase',round(v_final_base,4),
                'taxAmount',round(v_final_tax,4),
                'taxRounding',round(v_line_rounding,4),
                'grossAmount',round(
                    CASE WHEN v_price_mode = 'INCLUSIVE'
                         THEN v_amounts[v_index]
                         ELSE v_amounts[v_index] + v_final_tax END,
                    4
                )
            )
        );
    END LOOP;

    RETURN jsonb_build_object(
        'taxScope',v_scope,
        'priceMode',v_price_mode,
        'calculationScope',v_calculation_scope,
        'ratePercent',p_rate_percent,
        'lines',v_output_lines,
        'totalTaxBase',round(v_total_base,4),
        'totalTaxAmount',round(v_total_tax,4),
        'totalTaxRounding',round(v_total_rounding,4),
        'totalGrossAmount',round(v_total_gross,4)
    );
END;
$$;

REVOKE ALL ON FUNCTION private.resolve_product_tax_rule(
    UUID,UUID,TEXT,TIMESTAMPTZ
) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.calculate_tax_group(
    JSONB,NUMERIC,TEXT,TEXT,TEXT
) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.resolve_product_tax_rule(
    UUID,UUID,TEXT,TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION private.calculate_tax_group(
    JSONB,NUMERIC,TEXT,TEXT,TEXT
) TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260723070000',
    'g2_phase28_tax_resolver_calculator',
    'Private effective-dated Product override/Category Tax resolver and deterministic PER_LINE/PER_DOCUMENT IDR calculator; no transaction cutover'
);

COMMIT;

-- Forward-fix note:
-- Do not edit this migration after apply. Resolver/calculator correction must
-- use a later CREATE OR REPLACE migration and rerun behavioral regression.
