-- One-Company Product-UOM cutover: PACK remains usable for purchase and sale,
-- while DUS is retired from all new transactions.
--
-- This is an operational data correction, not a schema migration.
-- Historical transaction snapshots and their DUS references are preserved.
--
-- HOW TO RUN
-- 1. Change target_company_code to the exact Company code or Company UUID.
-- 2. Keep execute_change = FALSE and run the whole file for PREVIEW.
-- 3. Apply only when every BLOCKER row is PASS.
-- 4. Change execute_change = TRUE and confirmation exactly to:
--      ACTIVATE_PACK_DISABLE_DUS
-- 5. Run the whole file again, then restore execute_change = FALSE.

DROP TABLE IF EXISTS pg_temp.pack_only_config;
DROP TABLE IF EXISTS pg_temp.pack_only_target;
DROP TABLE IF EXISTS pg_temp.pack_only_plan;
DROP TABLE IF EXISTS pg_temp.pack_only_supplier_plan;
DROP TABLE IF EXISTS pg_temp.pack_only_pricelist_plan;
DROP TABLE IF EXISTS pg_temp.pack_only_result;

CREATE TEMP TABLE pack_only_config(
    target_company_code TEXT NOT NULL,
    execute_change BOOLEAN NOT NULL,
    confirmation TEXT NOT NULL
) ON COMMIT PRESERVE ROWS;

INSERT INTO pack_only_config(target_company_code,execute_change,confirmation)
VALUES (
    'GANTI_KODE_ATAU_ID_COMPANY', -- contoh: KMS atau UUID Company
    FALSE,                -- FALSE = PREVIEW, TRUE = APPLY
    ''                    -- APPLY: ACTIVATE_PACK_DISABLE_DUS
);

CREATE TEMP TABLE pack_only_target ON COMMIT PRESERVE ROWS AS
SELECT
    company.id AS company_id,
    company.company_code,
    company.company_name,
    COALESCE(company_actor.id,super_actor.id) AS actor_id
FROM pack_only_config config
JOIN public.companies company
  ON upper(btrim(company.company_code))=upper(btrim(config.target_company_code))
  OR company.id::TEXT=btrim(config.target_company_code)
LEFT JOIN LATERAL (
    SELECT membership.user_id AS id
    FROM public.company_memberships membership
    JOIN public.profiles profile ON profile.id=membership.user_id
    WHERE membership.company_id=company.id
      AND membership.status='ACTIVE'
      AND membership.role_code IN ('COMPANY_OWNER','COMPANY_ADMIN')
    ORDER BY CASE membership.role_code WHEN 'COMPANY_OWNER' THEN 0 ELSE 1 END,
             membership.user_id
    LIMIT 1
) company_actor ON TRUE
LEFT JOIN LATERAL (
    SELECT profile.id
    FROM public.profiles profile
    WHERE upper(profile.role::TEXT)='SUPER_ADMIN'
    ORDER BY profile.id
    LIMIT 1
) super_actor ON TRUE;

CREATE TEMP TABLE pack_only_plan ON COMMIT PRESERVE ROWS AS
SELECT
    product.company_id,
    product.id AS product_id,
    product.sku,
    product.name AS product_name,
    product.is_active AS product_is_active,
    product.uom_id AS base_uom_id,
    product.weight_reference_uom_id,
    product.weight_per_uom_kg,
    dus_uom.id AS dus_uom_id,
    dus_product_uom.id AS dus_product_uom_id,
    dus_product_uom.factor_to_base AS dus_factor,
    dus_product_uom.is_active AS dus_is_active,
    dus_product_uom.purchase_allowed AS dus_purchase_allowed,
    dus_product_uom.sales_allowed AS dus_sales_allowed,
    pack_uom.id AS pack_uom_id,
    pack_product_uom.id AS pack_product_uom_id,
    pack_product_uom.factor_to_base AS pack_factor,
    pack_product_uom.purchase_price AS pack_purchase_price,
    pack_product_uom.sale_price AS pack_sale_price,
    jsonb_build_object(
        'product',to_jsonb(product),
        'uoms',(
            SELECT COALESCE(jsonb_agg(to_jsonb(all_product_uom)
                ORDER BY all_product_uom.factor_to_base,all_product_uom.id),'[]'::JSONB)
            FROM public.product_uoms all_product_uom
            WHERE all_product_uom.company_id=product.company_id
              AND all_product_uom.product_id=product.id
        )
    ) AS before_product_snapshot
FROM pack_only_target target
JOIN public.products product ON product.company_id=target.company_id
JOIN public.product_uoms dus_product_uom
  ON dus_product_uom.company_id=product.company_id
 AND dus_product_uom.product_id=product.id
JOIN public.uoms dus_uom
  ON dus_uom.company_id=dus_product_uom.company_id
 AND dus_uom.id=dus_product_uom.uom_id
 AND (
     upper(btrim(dus_uom.code))='DUS'
     OR upper(btrim(dus_uom.name))='DUS'
 )
LEFT JOIN LATERAL (
    SELECT candidate_uom.id
    FROM public.uoms candidate_uom
    WHERE candidate_uom.company_id=product.company_id
      AND (
          upper(btrim(candidate_uom.code))='PACK'
          OR upper(btrim(candidate_uom.name))='PACK'
      )
    ORDER BY candidate_uom.is_active DESC,candidate_uom.id
    LIMIT 1
) pack_uom ON TRUE
LEFT JOIN public.product_uoms pack_product_uom
  ON pack_product_uom.company_id=product.company_id
 AND pack_product_uom.product_id=product.id
 AND pack_product_uom.uom_id=pack_uom.id;

CREATE TEMP TABLE pack_only_supplier_plan ON COMMIT PRESERVE ROWS AS
SELECT
    supplier_relation.company_id,
    supplier_relation.id AS product_supplier_id,
    plan.product_id,
    plan.sku,
    plan.dus_factor,
    plan.pack_factor,
    to_jsonb(supplier_relation) AS before_state
FROM pack_only_plan plan
JOIN public.product_suppliers supplier_relation
  ON supplier_relation.company_id=plan.company_id
 AND supplier_relation.product_id=plan.product_id
 AND supplier_relation.purchase_uom_id=plan.dus_uom_id
WHERE supplier_relation.is_active;

CREATE TEMP TABLE pack_only_pricelist_plan ON COMMIT PRESERVE ROWS AS
SELECT DISTINCT
    rule.company_id,
    rule.pricelist_id,
    jsonb_build_object(
        'pricelist',to_jsonb(pricelist),
        'rules',(
            SELECT COALESCE(jsonb_agg(to_jsonb(all_rule)
                ORDER BY all_rule.product_id,all_rule.product_uom_id,
                         all_rule.min_qty,all_rule.id),'[]'::JSONB)
            FROM public.pricelist_rules all_rule
            WHERE all_rule.company_id=pricelist.company_id
              AND all_rule.pricelist_id=pricelist.id
        )
    ) AS before_state
FROM pack_only_plan plan
JOIN public.pricelist_rules rule
  ON rule.company_id=plan.company_id
 AND rule.product_id=plan.product_id
 AND rule.product_uom_id=plan.dus_product_uom_id
 AND rule.is_active
JOIN public.pricelists pricelist
  ON pricelist.company_id=rule.company_id
 AND pricelist.id=rule.pricelist_id;

CREATE TEMP TABLE pack_only_result(
    check_name TEXT NOT NULL,
    status TEXT NOT NULL,
    details JSONB NOT NULL
) ON COMMIT PRESERVE ROWS;

DO $operation$
DECLARE
    v_config pack_only_config%ROWTYPE;
    v_target pack_only_target%ROWTYPE;
    v_company_count INTEGER;
    v_missing_pack INTEGER;
    v_invalid_pack_price INTEGER;
    v_dus_is_base INTEGER;
    v_invalid_factor INTEGER;
    v_invalid_scaled_weight INTEGER;
    v_bundle_rows INTEGER;
    v_product_count INTEGER;
    v_supplier_count INTEGER;
    v_rule_count INTEGER;
    v_pack_uom_count INTEGER;
    v_dus_uom_count INTEGER;
    v_before JSONB;
    v_after JSONB;
    v_row RECORD;
BEGIN
    SELECT * INTO v_config FROM pack_only_config;
    SELECT count(*) INTO v_company_count FROM pack_only_target;

    INSERT INTO pack_only_result(check_name,status,details)
    VALUES (
        'target_company',
        CASE WHEN v_company_count=1 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'requestedCompanyIdentifier',v_config.target_company_code,
            'matchedCompanies',v_company_count
        )
    );

    IF v_company_count<>1 THEN
        IF v_config.execute_change THEN
            RAISE EXCEPTION 'TARGET_COMPANY_NOT_FOUND_OR_AMBIGUOUS: %',
                v_config.target_company_code;
        END IF;
        RETURN;
    END IF;

    SELECT * INTO v_target FROM pack_only_target;

    INSERT INTO pack_only_result(check_name,status,details)
    VALUES (
        'audit_actor',
        CASE WHEN v_target.actor_id IS NOT NULL THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('actorId',v_target.actor_id)
    );

    SELECT count(*) INTO v_product_count FROM pack_only_plan;
    SELECT count(*) INTO v_missing_pack
    FROM pack_only_plan WHERE pack_product_uom_id IS NULL;
    SELECT count(*) INTO v_invalid_pack_price
    FROM pack_only_plan
    WHERE pack_product_uom_id IS NOT NULL
      AND (pack_purchase_price IS NULL OR pack_sale_price IS NULL);
    SELECT count(*) INTO v_dus_is_base
    FROM pack_only_plan WHERE base_uom_id=dus_uom_id;
    SELECT count(*) INTO v_invalid_factor
    FROM pack_only_plan
    WHERE pack_product_uom_id IS NOT NULL
      AND (pack_factor IS NULL OR dus_factor IS NULL
           OR pack_factor<=0 OR dus_factor<=pack_factor);
    SELECT count(*) INTO v_invalid_scaled_weight
    FROM pack_only_plan
    WHERE weight_reference_uom_id=dus_uom_id
      AND (
          weight_per_uom_kg IS NULL
          OR round(weight_per_uom_kg*pack_factor/dus_factor,3)<=0
      );
    SELECT count(*) INTO v_bundle_rows
    FROM pack_only_plan plan
    JOIN public.products product
      ON product.company_id=plan.company_id AND product.id=plan.product_id
    WHERE product.is_bundle;
    SELECT count(*) INTO v_supplier_count FROM pack_only_supplier_plan;
    SELECT count(*) INTO v_rule_count
    FROM pack_only_plan plan
    JOIN public.pricelist_rules rule
      ON rule.company_id=plan.company_id
     AND rule.product_id=plan.product_id
     AND rule.product_uom_id=plan.dus_product_uom_id
     AND rule.is_active;

    INSERT INTO pack_only_result(check_name,status,details) VALUES
    ('product_pack_pair_readiness',
     CASE WHEN v_product_count>0 AND v_missing_pack=0 THEN 'PASS' ELSE 'BLOCKER' END,
     jsonb_build_object(
         'productsWithDus',v_product_count,
         'productsMissingPack',v_missing_pack,
         'sampleMissingPack',COALESCE((
             SELECT jsonb_agg(sample_row)
             FROM (
                 SELECT jsonb_build_object('sku',sku,'productName',product_name)
                     AS sample_row
                 FROM pack_only_plan WHERE pack_product_uom_id IS NULL
                 ORDER BY sku LIMIT 20
             ) sample
         ),'[]'::JSONB)
     )),
    ('pack_price_readiness',
     CASE WHEN v_invalid_pack_price=0 THEN 'PASS' ELSE 'BLOCKER' END,
     jsonb_build_object(
         'productsWithoutPurchaseOrSalePrice',v_invalid_pack_price,
         'sample',COALESCE((
             SELECT jsonb_agg(sample_row)
             FROM (
                 SELECT jsonb_build_object(
                     'sku',sku,'purchasePrice',pack_purchase_price,
                     'salePrice',pack_sale_price
                 ) AS sample_row
                 FROM pack_only_plan
                 WHERE pack_product_uom_id IS NOT NULL
                   AND (pack_purchase_price IS NULL OR pack_sale_price IS NULL)
                 ORDER BY sku LIMIT 20
             ) sample
         ),'[]'::JSONB)
     )),
    ('dus_base_uom_boundary',
     CASE WHEN v_dus_is_base=0 THEN 'PASS' ELSE 'BLOCKER' END,
     jsonb_build_object('productsUsingDusAsBaseUom',v_dus_is_base)),
    ('pack_dus_conversion_shape',
     CASE WHEN v_invalid_factor=0 THEN 'PASS' ELSE 'BLOCKER' END,
     jsonb_build_object('invalidProductCount',v_invalid_factor)),
    ('pack_weight_conversion_shape',
     CASE WHEN v_invalid_scaled_weight=0 THEN 'PASS' ELSE 'BLOCKER' END,
     jsonb_build_object('invalidProductCount',v_invalid_scaled_weight)),
    ('bundle_boundary',
     CASE WHEN v_bundle_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
     jsonb_build_object('bundleProductsUsingDus',v_bundle_rows)),
    ('planned_master_effect',
     'INFO',
     jsonb_build_object(
         'products',v_product_count,
         'supplierRelationsRemapped',v_supplier_count,
         'activeDusPricelistRulesRetired',v_rule_count,
         'historyDeleted',FALSE
     ));

    IF NOT v_config.execute_change THEN
        INSERT INTO pack_only_result(check_name,status,details)
        VALUES ('operation_mode','PREVIEW',jsonb_build_object(
            'companyCode',v_target.company_code,
            'companyName',v_target.company_name,
            'writesExecuted',FALSE
        ));
        RETURN;
    END IF;

    IF v_config.confirmation IS DISTINCT FROM 'ACTIVATE_PACK_DISABLE_DUS' THEN
        RAISE EXCEPTION 'CONFIRMATION_REQUIRED: ACTIVATE_PACK_DISABLE_DUS';
    END IF;
    IF v_target.actor_id IS NULL THEN
        RAISE EXCEPTION 'AUDIT_ACTOR_NOT_FOUND';
    END IF;
    IF v_product_count=0 THEN
        RAISE EXCEPTION 'NO_DUS_PRODUCT_UOM_FOUND';
    END IF;
    IF v_missing_pack>0 OR v_invalid_pack_price>0 OR v_dus_is_base>0
       OR v_invalid_factor>0 OR v_invalid_scaled_weight>0 OR v_bundle_rows>0 THEN
        RAISE EXCEPTION 'PACK_ONLY_PRECONDITION_FAILED';
    END IF;

    -- Serialize the affected masters. Historical transaction rows are never
    -- updated by this operation.
    PERFORM product_uom.id
    FROM public.product_uoms product_uom
    JOIN pack_only_plan plan
      ON plan.company_id=product_uom.company_id
     AND plan.product_id=product_uom.product_id
     AND product_uom.id IN(plan.pack_product_uom_id,plan.dus_product_uom_id)
    FOR UPDATE;

    PERFORM supplier_relation.id
    FROM public.product_suppliers supplier_relation
    JOIN pack_only_supplier_plan plan
      ON plan.company_id=supplier_relation.company_id
     AND plan.product_supplier_id=supplier_relation.id
    FOR UPDATE;

    -- Active Supplier relations continue in PACK. Prices stored per purchase
    -- UOM are converted proportionally from DUS to PACK.
    FOR v_row IN SELECT * FROM pack_only_supplier_plan ORDER BY product_supplier_id
    LOOP
        UPDATE public.product_suppliers supplier_relation
        SET purchase_uom_id=(
                SELECT plan.pack_uom_id FROM pack_only_plan plan
                WHERE plan.company_id=v_row.company_id
                  AND plan.product_id=v_row.product_id
            ),
            reference_purchase_price=CASE
                WHEN supplier_relation.reference_purchase_price IS NULL THEN NULL
                ELSE round(supplier_relation.reference_purchase_price
                           * v_row.pack_factor/v_row.dus_factor,4)
            END,
            last_purchase_price=CASE
                WHEN supplier_relation.last_purchase_price IS NULL THEN NULL
                ELSE round(supplier_relation.last_purchase_price
                           * v_row.pack_factor/v_row.dus_factor,4)
            END,
            updated_by=v_target.actor_id
        WHERE supplier_relation.company_id=v_row.company_id
          AND supplier_relation.id=v_row.product_supplier_id;

        SELECT to_jsonb(supplier_relation) INTO v_after
        FROM public.product_suppliers supplier_relation
        WHERE supplier_relation.company_id=v_row.company_id
          AND supplier_relation.id=v_row.product_supplier_id;

        INSERT INTO public.product_supplier_audit(
            company_id,product_supplier_id,action,actor_id,before_state,after_state
        ) VALUES (
            v_row.company_id,v_row.product_supplier_id,'UPDATE',v_target.actor_id,
            v_row.before_state,v_after
        );
    END LOOP;

    -- Retire DUS-only active Pricelist rules. PACK rules remain untouched.
    UPDATE public.pricelist_rules rule
    SET is_active=FALSE,updated_by=v_target.actor_id
    FROM pack_only_plan plan
    WHERE rule.company_id=plan.company_id
      AND rule.product_id=plan.product_id
      AND rule.product_uom_id=plan.dus_product_uom_id
      AND rule.is_active;

    FOR v_row IN SELECT * FROM pack_only_pricelist_plan ORDER BY pricelist_id
    LOOP
        SELECT jsonb_build_object(
            'pricelist',to_jsonb(pricelist),
            'rules',(
                SELECT COALESCE(jsonb_agg(to_jsonb(rule)
                    ORDER BY rule.product_id,rule.product_uom_id,
                             rule.min_qty,rule.id),'[]'::JSONB)
                FROM public.pricelist_rules rule
                WHERE rule.company_id=pricelist.company_id
                  AND rule.pricelist_id=pricelist.id
            )
        ) INTO v_after
        FROM public.pricelists pricelist
        WHERE pricelist.company_id=v_row.company_id
          AND pricelist.id=v_row.pricelist_id;

        INSERT INTO public.pricelist_master_audit(
            company_id,pricelist_id,action,actor_id,before_state,after_state
        ) VALUES (
            v_row.company_id,v_row.pricelist_id,'UPDATE',v_target.actor_id,
            v_row.before_state,v_after
        );
    END LOOP;

    -- If DUS was the weight reference, preserve the same physical weight by
    -- scaling it to one PACK.
    UPDATE public.products product
    SET weight_reference_uom_id=plan.pack_uom_id,
        weight_per_uom_kg=round(
            product.weight_per_uom_kg*plan.pack_factor/plan.dus_factor,3
        ),
        updated_by=v_target.actor_id
    FROM pack_only_plan plan
    WHERE product.company_id=plan.company_id
      AND product.id=plan.product_id
      AND product.weight_reference_uom_id=plan.dus_uom_id;

    UPDATE public.product_uoms product_uom
    SET purchase_allowed=TRUE,
        sales_allowed=TRUE,
        is_active=TRUE,
        updated_by=v_target.actor_id
    FROM pack_only_plan plan
    WHERE product_uom.company_id=plan.company_id
      AND product_uom.id=plan.pack_product_uom_id;

    UPDATE public.product_uoms product_uom
    SET purchase_allowed=FALSE,
        sales_allowed=FALSE,
        is_active=FALSE,
        updated_by=v_target.actor_id
    FROM pack_only_plan plan
    WHERE product_uom.company_id=plan.company_id
      AND product_uom.id=plan.dus_product_uom_id;

    FOR v_row IN SELECT * FROM pack_only_plan ORDER BY sku,product_id
    LOOP
        SELECT jsonb_build_object(
            'product',to_jsonb(product),
            'uoms',(
                SELECT COALESCE(jsonb_agg(to_jsonb(product_uom)
                    ORDER BY product_uom.factor_to_base,product_uom.id),'[]'::JSONB)
                FROM public.product_uoms product_uom
                WHERE product_uom.company_id=product.company_id
                  AND product_uom.product_id=product.id
            )
        ) INTO v_after
        FROM public.products product
        WHERE product.company_id=v_row.company_id
          AND product.id=v_row.product_id;

        INSERT INTO public.product_master_audit(
            company_id,product_id,action,actor_id,before_snapshot,after_snapshot
        ) VALUES (
            v_row.company_id,v_row.product_id,'UPDATE',v_target.actor_id,
            v_row.before_product_snapshot,v_after
        );
    END LOOP;

    -- Company UOM availability follows the final Product-UOM state. PACK is
    -- activated; DUS is deactivated only when no active DUS Product-UOM remains.
    FOR v_row IN
        SELECT uom.*,to_jsonb(uom) AS before_state
        FROM public.uoms uom
        WHERE uom.company_id=v_target.company_id
          AND (
              upper(btrim(uom.code)) IN ('PACK','DUS')
              OR upper(btrim(uom.name)) IN ('PACK','DUS')
          )
        FOR UPDATE
    LOOP
        IF upper(btrim(v_row.code))='PACK' OR upper(btrim(v_row.name))='PACK' THEN
            UPDATE public.uoms SET is_active=TRUE,updated_by=v_target.actor_id
            WHERE company_id=v_target.company_id AND id=v_row.id;
        ELSIF NOT EXISTS(
            SELECT 1 FROM public.product_uoms product_uom
            WHERE product_uom.company_id=v_target.company_id
              AND product_uom.uom_id=v_row.id
              AND product_uom.is_active
        ) THEN
            UPDATE public.uoms SET is_active=FALSE,updated_by=v_target.actor_id
            WHERE company_id=v_target.company_id AND id=v_row.id;
        END IF;

        SELECT to_jsonb(uom) INTO v_after FROM public.uoms uom
        WHERE uom.company_id=v_target.company_id AND uom.id=v_row.id;
        IF v_row.before_state IS DISTINCT FROM v_after THEN
            INSERT INTO public.inventory_master_write_audit(
                company_id,master_type,master_id,actor_id,action,
                before_state,after_state
            ) VALUES (
                v_target.company_id,'UOM',v_row.id,v_target.actor_id,'UPDATE',
                v_row.before_state,v_after
            );
        END IF;
    END LOOP;

    SELECT count(*) INTO v_pack_uom_count
    FROM pack_only_plan plan
    JOIN public.product_uoms product_uom
      ON product_uom.company_id=plan.company_id
     AND product_uom.id=plan.pack_product_uom_id
    JOIN public.uoms uom
      ON uom.company_id=product_uom.company_id AND uom.id=product_uom.uom_id
    WHERE product_uom.company_id=v_target.company_id
      AND (upper(btrim(uom.code))='PACK' OR upper(btrim(uom.name))='PACK')
      AND product_uom.is_active
      AND product_uom.purchase_allowed
      AND product_uom.sales_allowed;

    SELECT count(*) INTO v_dus_uom_count
    FROM pack_only_plan plan
    JOIN public.product_uoms product_uom
      ON product_uom.company_id=plan.company_id
     AND product_uom.id=plan.dus_product_uom_id
    JOIN public.uoms uom
      ON uom.company_id=product_uom.company_id AND uom.id=product_uom.uom_id
    WHERE product_uom.company_id=v_target.company_id
      AND (upper(btrim(uom.code))='DUS' OR upper(btrim(uom.name))='DUS')
      AND (product_uom.is_active OR product_uom.purchase_allowed
           OR product_uom.sales_allowed);

    IF v_pack_uom_count<>v_product_count OR v_dus_uom_count<>0 THEN
        RAISE EXCEPTION 'PACK_ONLY_POSTCONDITION_FAILED';
    END IF;

    INSERT INTO pack_only_result(check_name,status,details)
    VALUES (
        'operation_mode','APPLIED',jsonb_build_object(
            'companyCode',v_target.company_code,
            'companyName',v_target.company_name,
            'productsChanged',v_product_count,
            'supplierRelationsRemapped',v_supplier_count,
            'activeDusPricelistRulesRetired',v_rule_count,
            'packPurchaseAndSalesRows',v_pack_uom_count,
            'remainingActiveDusRows',v_dus_uom_count,
            'historyDeleted',FALSE,
            'writesExecuted',TRUE
        )
    );
END
$operation$;

SELECT check_name,status,details
FROM pack_only_result
ORDER BY CASE status
    WHEN 'BLOCKER' THEN 0
    WHEN 'PASS' THEN 1
    WHEN 'PREVIEW' THEN 2
    WHEN 'APPLIED' THEN 3
    ELSE 4
END,check_name;
