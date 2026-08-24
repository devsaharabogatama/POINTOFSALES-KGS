-- Forward fix: missing distributor SKU is explicitly skipped.
-- The base distributor Pricelist migration may already be installed.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260824100000'
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: distributor Pricelist import required';
  END IF;
  IF EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260824110000'
  ) THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260824110000';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION public.process_distributor_pricelist_import(
  p_rows JSONB,
  p_source_file_name TEXT,
  p_source_file_checksum TEXT,
  p_client_request_id UUID DEFAULT NULL,
  p_apply BOOLEAN DEFAULT FALSE,
  p_confirmation TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_actor UUID:=auth.uid();
  v_company UUID:=public.private_active_company_id();
  v_existing_run public.pricelist_import_runs%ROWTYPE;
  v_source JSONB;
  v_index INTEGER;
  v_plan_rows JSONB;
  v_result JSONB;
  v_configuration_errors JSONB:='[]'::JSONB;
  v_error_count INTEGER;
  v_skipped_count INTEGER;
  v_warning_count INTEGER;
  v_valid_count INTEGER;
  v_uom_updates INTEGER;
  v_rule_count INTEGER;
  v_changed_products INTEGER:=0;
  v_changed_pricelists INTEGER:=0;
  v_product RECORD;
  v_before JSONB;
  v_after JSONB;
  v_profile_key TEXT;
  v_profile_name TEXT;
  v_profile_priority INTEGER;
  v_profile_id UUID;
  v_profile_version BIGINT;
  v_profile RECORD;
  v_rules JSONB;
  v_save_result JSONB;
  v_default RECORD;
  v_row_count INTEGER;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.pricelists','IMPORT');
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.products','IMPORT');

  IF p_rows IS NULL OR jsonb_typeof(p_rows)<>'array' THEN
    RAISE EXCEPTION 'PRICELIST_IMPORT_ROWS_REQUIRED';
  END IF;
  v_row_count:=jsonb_array_length(p_rows);
  IF v_row_count<1 OR v_row_count>500 THEN
    RAISE EXCEPTION 'PRICELIST_IMPORT_ROW_LIMIT';
  END IF;
  IF btrim(COALESCE(p_source_file_name,''))='' OR length(p_source_file_name)>255 THEN
    RAISE EXCEPTION 'PRICELIST_IMPORT_FILE_NAME_INVALID';
  END IF;
  IF lower(COALESCE(p_source_file_checksum,''))!~'^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'PRICELIST_IMPORT_CHECKSUM_INVALID';
  END IF;

  DROP TABLE IF EXISTS pg_temp.kgs_distributor_pricelist_rows;
  CREATE TEMP TABLE kgs_distributor_pricelist_rows(
    row_number INTEGER NOT NULL,
    normalized_sku TEXT,
    source_sku TEXT,
    source_name TEXT,
    cogs NUMERIC(20,4),
    retail NUMERIC(20,4),
    agent_price NUMERIC(20,4),
    special_price NUMERIC(20,4),
    custom_price NUMERIC(20,4),
    min_60_price NUMERIC(20,4),
    min_100_price NUMERIC(20,4),
    min_150_price NUMERIC(20,4),
    product_id UUID,
    product_name TEXT,
    pack_uom_id UUID,
    pack_factor NUMERIC(24,6),
    dus_uom_id UUID,
    dus_factor NUMERIC(24,6),
    pack_uom_count INTEGER NOT NULL DEFAULT 0,
    active_uom_count INTEGER NOT NULL DEFAULT 0,
    errors JSONB NOT NULL DEFAULT '[]'::JSONB,
    warnings JSONB NOT NULL DEFAULT '[]'::JSONB
  ) ON COMMIT DROP;

  v_index:=0;
  FOR v_source IN SELECT value FROM jsonb_array_elements(p_rows)
  LOOP
    v_index:=v_index+1;
    IF jsonb_typeof(v_source)<>'object' THEN
      INSERT INTO kgs_distributor_pricelist_rows(row_number,errors)
      VALUES(v_index+1,'["INVALID_ROW"]'::JSONB);
      CONTINUE;
    END IF;
    INSERT INTO kgs_distributor_pricelist_rows(
      row_number,normalized_sku,source_sku,source_name,cogs,retail,
      agent_price,special_price,custom_price,min_60_price,min_100_price,
      min_150_price,errors
    ) VALUES(
      COALESCE(CASE WHEN jsonb_typeof(v_source->'rowNumber')='number'
        THEN (v_source->>'rowNumber')::INTEGER END,v_index+1),
      upper(regexp_replace(btrim(COALESCE(v_source->>'sku','')),'\s+',' ','g')),
      btrim(COALESCE(v_source->>'sku','')),
      NULLIF(btrim(COALESCE(v_source->>'productName','')),''),
      CASE WHEN jsonb_typeof(v_source->'cogs')='number'
        THEN round((v_source->>'cogs')::NUMERIC,4) END,
      CASE WHEN jsonb_typeof(v_source->'retail')='number'
        THEN round((v_source->>'retail')::NUMERIC,4) END,
      CASE WHEN jsonb_typeof(v_source->'agentPrice')='number'
        THEN round((v_source->>'agentPrice')::NUMERIC,4) END,
      CASE WHEN jsonb_typeof(v_source->'specialPrice')='number'
        THEN round((v_source->>'specialPrice')::NUMERIC,4) END,
      CASE WHEN jsonb_typeof(v_source->'customPrice')='number'
        THEN round((v_source->>'customPrice')::NUMERIC,4) END,
      CASE WHEN jsonb_typeof(v_source->'min60Price')='number'
        THEN round((v_source->>'min60Price')::NUMERIC,4) END,
      CASE WHEN jsonb_typeof(v_source->'min100Price')='number'
        THEN round((v_source->>'min100Price')::NUMERIC,4) END,
      CASE WHEN jsonb_typeof(v_source->'min150Price')='number'
        THEN round((v_source->>'min150Price')::NUMERIC,4) END,
      CASE WHEN btrim(COALESCE(v_source->>'sku',''))=''
        THEN '["SKU_REQUIRED"]'::JSONB ELSE '[]'::JSONB END
        || CASE WHEN NOT(v_source?'cogs') OR jsonb_typeof(v_source->'cogs')<>'number'
          THEN '["COGS_REQUIRED"]'::JSONB ELSE '[]'::JSONB END
        || CASE WHEN NOT(v_source?'retail') OR jsonb_typeof(v_source->'retail')<>'number'
          THEN '["RETAIL_PRICE_REQUIRED"]'::JSONB ELSE '[]'::JSONB END
        || CASE WHEN EXISTS(SELECT 1 FROM jsonb_each(v_source) item
            WHERE item.key IN('cogs','retail','agentPrice','specialPrice','customPrice',
              'min60Price','min100Price','min150Price')
              AND jsonb_typeof(item.value)='number' AND (item.value#>>'{}')::NUMERIC<0)
          THEN '["NEGATIVE_PRICE"]'::JSONB ELSE '[]'::JSONB END
    );
  END LOOP;

  UPDATE kgs_distributor_pricelist_rows target SET errors=target.errors||'["DUPLICATE_SKU_IN_FILE"]'::JSONB
  WHERE target.normalized_sku IN(
    SELECT normalized_sku FROM kgs_distributor_pricelist_rows
    WHERE normalized_sku<>'' GROUP BY normalized_sku HAVING count(*)>1
  );

  WITH matched AS(
    SELECT target.ctid AS target_ctid,product.id,product.name
    FROM kgs_distributor_pricelist_rows target
    JOIN public.products product ON product.company_id=v_company
      AND upper(regexp_replace(btrim(product.sku),'\s+',' ','g'))=target.normalized_sku
      AND product.is_active AND NOT product.is_bundle
  )
  UPDATE kgs_distributor_pricelist_rows target SET
    product_id=matched.id,product_name=matched.name
  FROM matched WHERE target.ctid=matched.target_ctid;

  UPDATE kgs_distributor_pricelist_rows target
  SET warnings=target.warnings||'["ACTIVE_PRODUCT_SKU_NOT_FOUND_SKIPPED"]'::JSONB
  WHERE target.product_id IS NULL;

  WITH matched AS(
    SELECT DISTINCT ON(target.ctid) target.ctid AS target_ctid,
      product_uom.id,product_uom.factor_to_base
    FROM kgs_distributor_pricelist_rows target
    JOIN public.product_uoms product_uom ON product_uom.company_id=v_company
      AND product_uom.product_id=target.product_id
    JOIN public.uoms uom ON uom.company_id=product_uom.company_id
      AND uom.id=product_uom.uom_id
    WHERE product_uom.is_active AND product_uom.sales_allowed
      AND (upper(btrim(uom.name))='PACK' OR upper(btrim(uom.code))='PACK')
    ORDER BY target.ctid,product_uom.factor_to_base,product_uom.id
  )
  UPDATE kgs_distributor_pricelist_rows target SET
    pack_uom_id=matched.id,pack_factor=matched.factor_to_base
  FROM matched WHERE target.ctid=matched.target_ctid;

  UPDATE kgs_distributor_pricelist_rows target
  SET errors=target.errors||'["ACTIVE_PACK_SALES_UOM_NOT_FOUND"]'::JSONB
  WHERE target.product_id IS NOT NULL AND target.pack_uom_id IS NULL;

  UPDATE kgs_distributor_pricelist_rows target SET
    pack_uom_count=(SELECT count(*)
      FROM public.product_uoms product_uom
      JOIN public.uoms uom ON uom.company_id=product_uom.company_id
        AND uom.id=product_uom.uom_id
      WHERE product_uom.company_id=v_company
        AND product_uom.product_id=target.product_id
        AND product_uom.is_active AND product_uom.sales_allowed
        AND (upper(btrim(uom.name))='PACK' OR upper(btrim(uom.code))='PACK'))
  WHERE target.product_id IS NOT NULL;

  UPDATE kgs_distributor_pricelist_rows target
  SET errors=target.errors||'["AMBIGUOUS_ACTIVE_PACK_SALES_UOM"]'::JSONB
  WHERE target.pack_uom_count>1;

  WITH matched AS(
    SELECT DISTINCT ON(target.ctid) target.ctid AS target_ctid,
      product_uom.id,product_uom.factor_to_base
    FROM kgs_distributor_pricelist_rows target
    JOIN public.product_uoms product_uom ON product_uom.company_id=v_company
      AND product_uom.product_id=target.product_id
    JOIN public.uoms uom ON uom.company_id=product_uom.company_id
      AND uom.id=product_uom.uom_id
    WHERE product_uom.is_active
      AND (upper(btrim(uom.name))='DUS' OR upper(btrim(uom.code))='DUS')
    ORDER BY target.ctid,product_uom.factor_to_base DESC,product_uom.id
  )
  UPDATE kgs_distributor_pricelist_rows target SET
    dus_uom_id=matched.id,dus_factor=matched.factor_to_base
  FROM matched WHERE target.ctid=matched.target_ctid;

  UPDATE kgs_distributor_pricelist_rows target SET
    active_uom_count=(SELECT count(*) FROM public.product_uoms product_uom
      WHERE product_uom.company_id=v_company AND product_uom.product_id=target.product_id
        AND product_uom.is_active),
    warnings=target.warnings||CASE WHEN target.dus_uom_id IS NULL
      THEN '["DUS_UOM_NOT_FOUND_SKIPPED"]'::JSONB ELSE '[]'::JSONB END
  WHERE target.product_id IS NOT NULL;

  IF (SELECT count(*) FROM public.pricelists pricelist
      WHERE pricelist.company_id=v_company AND pricelist.scope='GLOBAL'
        AND pricelist.is_active AND pricelist.is_default)<>1 THEN
    v_configuration_errors:=v_configuration_errors||'["EXACT_ONE_DEFAULT_GLOBAL_PRICELIST_REQUIRED"]'::JSONB;
  END IF;
  FOR v_profile_name IN SELECT unnest(ARRAY[
    'Harga Agen / SM','Harga Spesial','Harga Khusus'
  ]) LOOP
    IF (SELECT count(*) FROM public.pricelists pricelist
        WHERE pricelist.company_id=v_company
          AND lower(regexp_replace(btrim(pricelist.name),'\s+',' ','g'))=
              lower(regexp_replace(btrim(v_profile_name),'\s+',' ','g'))) > 1 THEN
      v_configuration_errors:=v_configuration_errors||jsonb_build_array(
        'AMBIGUOUS_PRICELIST_NAME:'||v_profile_name);
    END IF;
    IF EXISTS(SELECT 1 FROM public.pricelists pricelist
        WHERE pricelist.company_id=v_company AND NOT pricelist.is_active
          AND lower(regexp_replace(btrim(pricelist.name),'\s+',' ','g'))=
              lower(regexp_replace(btrim(v_profile_name),'\s+',' ','g'))) THEN
      v_configuration_errors:=v_configuration_errors||jsonb_build_array(
        'IMPORT_PRICELIST_INACTIVE:'||v_profile_name);
    END IF;
  END LOOP;

  SELECT count(*) FILTER(WHERE jsonb_array_length(errors)=0 AND product_id IS NOT NULL),
    count(*) FILTER(WHERE jsonb_array_length(errors)>0),
    count(*) FILTER(WHERE jsonb_array_length(errors)=0 AND product_id IS NULL),
    count(*) FILTER(WHERE jsonb_array_length(warnings)>0),
    COALESCE(sum(active_uom_count) FILTER(
      WHERE jsonb_array_length(errors)=0 AND product_id IS NOT NULL),0)
  INTO v_valid_count,v_error_count,v_skipped_count,v_warning_count,v_uom_updates
  FROM kgs_distributor_pricelist_rows;

  IF v_valid_count=0 THEN
    v_configuration_errors:=v_configuration_errors||'["NO_MATCHED_PRODUCT_SKU"]'::JSONB;
  END IF;

  SELECT COALESCE(sum(
    ((agent_price IS NOT NULL)::INTEGER+(special_price IS NOT NULL)::INTEGER+
     (custom_price IS NOT NULL)::INTEGER+(min_60_price IS NOT NULL)::INTEGER+
     (min_100_price IS NOT NULL)::INTEGER+(min_150_price IS NOT NULL)::INTEGER)
    * active_uom_count
  ) FILTER(WHERE jsonb_array_length(errors)=0),0)
  INTO v_rule_count FROM kgs_distributor_pricelist_rows;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'rowNumber',row_number,'sku',source_sku,'sourceProductName',source_name,
    'productName',product_name,'status',CASE
      WHEN jsonb_array_length(errors)>0 THEN 'ERROR'
      WHEN product_id IS NULL THEN 'SKIPPED' ELSE 'VALID' END,
    'errors',errors,'warnings',warnings,
    'packFactor',pack_factor,'dusFactor',dus_factor,
    'retail',retail,'cogs',cogs,'agentPrice',agent_price,
    'specialPrice',special_price,'customPrice',custom_price,
    'min60Price',min_60_price,'min100Price',min_100_price,
    'min150Price',min_150_price
  ) ORDER BY row_number),'[]'::JSONB) INTO v_plan_rows
  FROM kgs_distributor_pricelist_rows;

  v_result:=jsonb_build_object(
    'companyId',v_company,'mode',CASE WHEN p_apply THEN 'APPLY' ELSE 'PREVIEW' END,
    'sourceRowCount',v_row_count,'validRowCount',v_valid_count,
    'errorRowCount',v_error_count,'skippedRowCount',v_skipped_count,
    'warningRowCount',v_warning_count,
    'productUomPriceUpdates',v_uom_updates,'pricelistRuleUpdates',v_rule_count,
    'configurationErrors',v_configuration_errors,'rows',v_plan_rows,
    'pricePolicy',jsonb_build_object(
      'sourceUom','PACK','derivedFormula','source_price / pack_factor * target_factor',
      'tiers','60/100/150 PACK converted to Base UOM equivalent'));

  IF NOT p_apply THEN RETURN v_result; END IF;
  IF p_confirmation IS DISTINCT FROM 'IMPORT_DISTRIBUTOR_PRICELIST' THEN
    RAISE EXCEPTION 'PRICELIST_IMPORT_CONFIRMATION_REQUIRED';
  END IF;
  IF p_client_request_id IS NULL THEN RAISE EXCEPTION 'CLIENT_REQUEST_ID_REQUIRED'; END IF;
  IF v_error_count>0 OR jsonb_array_length(v_configuration_errors)>0 THEN
    RAISE EXCEPTION 'PRICELIST_IMPORT_HAS_ERRORS';
  END IF;

  SELECT * INTO v_existing_run FROM public.pricelist_import_runs run
  WHERE run.company_id=v_company AND run.client_request_id=p_client_request_id
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing_run.source_file_checksum=lower(p_source_file_checksum) THEN
      RETURN v_existing_run.result_snapshot||jsonb_build_object('replayed',TRUE);
    END IF;
    RAISE EXCEPTION 'PRICELIST_IMPORT_IDEMPOTENCY_CONFLICT';
  END IF;

  FOR v_product IN
    SELECT DISTINCT source.product_id,source.pack_factor,source.cogs,source.retail
    FROM kgs_distributor_pricelist_rows source
    WHERE source.product_id IS NOT NULL ORDER BY source.product_id
  LOOP
    PERFORM 1 FROM public.products product
    WHERE product.company_id=v_company AND product.id=v_product.product_id FOR UPDATE;
    SELECT jsonb_build_object('product',to_jsonb(product),'uoms',COALESCE((
      SELECT jsonb_agg(to_jsonb(product_uom) ORDER BY product_uom.factor_to_base,product_uom.id)
      FROM public.product_uoms product_uom WHERE product_uom.company_id=v_company
        AND product_uom.product_id=v_product.product_id),'[]'::JSONB))
    INTO v_before FROM public.products product
    WHERE product.company_id=v_company AND product.id=v_product.product_id;

    UPDATE public.product_uoms product_uom SET
      purchase_price=round(v_product.cogs/v_product.pack_factor*product_uom.factor_to_base,4),
      sale_price=round(v_product.retail/v_product.pack_factor*product_uom.factor_to_base,4),
      updated_by=v_actor
    WHERE product_uom.company_id=v_company
      AND product_uom.product_id=v_product.product_id AND product_uom.is_active
      AND (product_uom.purchase_price IS DISTINCT FROM
            round(v_product.cogs/v_product.pack_factor*product_uom.factor_to_base,4)
        OR product_uom.sale_price IS DISTINCT FROM
            round(v_product.retail/v_product.pack_factor*product_uom.factor_to_base,4));

    UPDATE public.products product SET
      cogs=round(v_product.cogs/v_product.pack_factor,4),
      price=round(v_product.retail/v_product.pack_factor,4),updated_by=v_actor
    WHERE product.company_id=v_company AND product.id=v_product.product_id
      AND (product.cogs IS DISTINCT FROM round(v_product.cogs/v_product.pack_factor,4)
        OR product.price IS DISTINCT FROM round(v_product.retail/v_product.pack_factor,4));

    SELECT jsonb_build_object('product',to_jsonb(product),'uoms',COALESCE((
      SELECT jsonb_agg(to_jsonb(product_uom) ORDER BY product_uom.factor_to_base,product_uom.id)
      FROM public.product_uoms product_uom WHERE product_uom.company_id=v_company
        AND product_uom.product_id=v_product.product_id),'[]'::JSONB))
    INTO v_after FROM public.products product
    WHERE product.company_id=v_company AND product.id=v_product.product_id;
    IF v_before IS DISTINCT FROM v_after THEN
      INSERT INTO public.product_master_audit(
        company_id,product_id,action,actor_id,before_snapshot,after_snapshot
      ) VALUES(v_company,v_product.product_id,'UPDATE',v_actor,v_before,v_after);
      v_changed_products:=v_changed_products+1;
    END IF;
  END LOOP;

  FOREACH v_profile_key IN ARRAY ARRAY['agent_price','special_price','custom_price']
  LOOP
    v_profile_name:=CASE v_profile_key WHEN 'agent_price' THEN 'Harga Agen / SM'
      WHEN 'special_price' THEN 'Harga Spesial' ELSE 'Harga Khusus' END;
    v_profile_priority:=CASE v_profile_key WHEN 'agent_price' THEN 30
      WHEN 'special_price' THEN 20 ELSE 10 END;
    IF NOT EXISTS(SELECT 1 FROM kgs_distributor_pricelist_rows source
      WHERE CASE v_profile_key WHEN 'agent_price' THEN source.agent_price
        WHEN 'special_price' THEN source.special_price ELSE source.custom_price END IS NOT NULL)
    THEN CONTINUE; END IF;

    SELECT pricelist.* INTO v_profile FROM public.pricelists pricelist
    WHERE pricelist.company_id=v_company
      AND lower(regexp_replace(btrim(pricelist.name),'\s+',' ','g'))=
          lower(regexp_replace(btrim(v_profile_name),'\s+',' ','g'))
    LIMIT 1 FOR UPDATE;
    IF FOUND AND v_profile.scope<>'CUSTOMER' THEN
      RAISE EXCEPTION 'IMPORT_PRICELIST_SCOPE_CONFLICT:%',v_profile_name;
    END IF;

    SELECT COALESCE(jsonb_agg(rule_payload),'[]'::JSONB) INTO v_rules FROM(
      SELECT jsonb_build_object('productId',rule.product_id,
        'productUomId',rule.product_uom_id,'minQty',rule.min_qty,
        'tierQtyBasis',rule.tier_qty_basis,'pricingMethod',rule.pricing_method,
        'fixedUnitPrice',rule.fixed_unit_price,
        'discountAmountPerUnit',rule.discount_amount_per_unit,
        'discountPercent',rule.discount_percent,'validFrom',rule.valid_from,
        'validUntil',rule.valid_until,'isActive',TRUE) rule_payload
      FROM public.pricelist_rules rule
      WHERE v_profile.id IS NOT NULL AND rule.company_id=v_company
        AND rule.pricelist_id=v_profile.id AND rule.is_active
        AND NOT EXISTS(SELECT 1 FROM kgs_distributor_pricelist_rows source
          WHERE source.product_id=rule.product_id AND
            CASE v_profile_key WHEN 'agent_price' THEN source.agent_price
              WHEN 'special_price' THEN source.special_price ELSE source.custom_price END IS NOT NULL)
      UNION ALL
      SELECT jsonb_build_object('productId',source.product_id,
        'productUomId',product_uom.id,'minQty',1,
        'tierQtyBasis','BASE_UOM_EQUIVALENT','pricingMethod','FIXED_PRICE',
        'fixedUnitPrice',round((CASE v_profile_key
          WHEN 'agent_price' THEN source.agent_price
          WHEN 'special_price' THEN source.special_price ELSE source.custom_price END)
          /source.pack_factor*product_uom.factor_to_base,4),'isActive',TRUE)
      FROM kgs_distributor_pricelist_rows source
      JOIN public.product_uoms product_uom ON product_uom.company_id=v_company
        AND product_uom.product_id=source.product_id
        AND product_uom.is_active AND product_uom.sales_allowed
      WHERE CASE v_profile_key WHEN 'agent_price' THEN source.agent_price
        WHEN 'special_price' THEN source.special_price ELSE source.custom_price END IS NOT NULL
    ) rules;

    -- The importer already enforces IMPORT for both Pricelist and Product.
    -- Use the quarantined transactional core so IMPORT is not accidentally
    -- widened into, or blocked by, the separate interactive MANAGE contract.
    v_save_result:=private.acp5f_save_reusable_pricelist_with_rules_core(
      CASE WHEN v_profile.id IS NULL THEN NULL ELSE v_profile.id END,
      CASE WHEN v_profile.id IS NULL THEN NULL ELSE v_profile.master_version END,
      v_profile_name,'CUSTOMER',
      COALESCE(v_profile.priority,v_profile_priority),FALSE,
      COALESCE(v_profile.applies_all_stores,TRUE),
      CASE WHEN v_profile.id IS NULL OR v_profile.applies_all_stores THEN ARRAY[]::UUID[]
        ELSE ARRAY(SELECT assignment.store_id FROM public.pricelist_store_assignments assignment
          WHERE assignment.company_id=v_company AND assignment.pricelist_id=v_profile.id) END,
      v_profile.valid_from,v_profile.valid_until,COALESCE(v_profile.is_active,TRUE),
      COALESCE(v_profile.notes,'Diimpor dari Price List Distributor'),v_rules);
    v_changed_pricelists:=v_changed_pricelists+1;
  END LOOP;

  SELECT pricelist.* INTO v_default FROM public.pricelists pricelist
  WHERE pricelist.company_id=v_company AND pricelist.scope='GLOBAL'
    AND pricelist.is_active AND pricelist.is_default FOR UPDATE;
  IF EXISTS(SELECT 1 FROM kgs_distributor_pricelist_rows source
    WHERE source.min_60_price IS NOT NULL OR source.min_100_price IS NOT NULL
      OR source.min_150_price IS NOT NULL) THEN
    SELECT COALESCE(jsonb_agg(rule_payload),'[]'::JSONB) INTO v_rules FROM(
      SELECT jsonb_build_object('productId',rule.product_id,
        'productUomId',rule.product_uom_id,'minQty',rule.min_qty,
        'tierQtyBasis',rule.tier_qty_basis,'pricingMethod',rule.pricing_method,
        'fixedUnitPrice',rule.fixed_unit_price,
        'discountAmountPerUnit',rule.discount_amount_per_unit,
        'discountPercent',rule.discount_percent,'validFrom',rule.valid_from,
        'validUntil',rule.valid_until,'isActive',TRUE) rule_payload
      FROM public.pricelist_rules rule
      WHERE rule.company_id=v_company AND rule.pricelist_id=v_default.id
        AND rule.is_active AND NOT EXISTS(
          SELECT 1 FROM kgs_distributor_pricelist_rows source
          WHERE source.product_id=rule.product_id AND(
            (source.min_60_price IS NOT NULL AND rule.min_qty=60*source.pack_factor)
            OR (source.min_100_price IS NOT NULL AND rule.min_qty=100*source.pack_factor)
            OR (source.min_150_price IS NOT NULL AND rule.min_qty=150*source.pack_factor)))
      UNION ALL
      SELECT jsonb_build_object('productId',source.product_id,
        'productUomId',product_uom.id,'minQty',tier.pack_qty*source.pack_factor,
        'tierQtyBasis','BASE_UOM_EQUIVALENT','pricingMethod','FIXED_PRICE',
        'fixedUnitPrice',round(tier.pack_price/source.pack_factor
          *product_uom.factor_to_base,4),'isActive',TRUE)
      FROM kgs_distributor_pricelist_rows source
      CROSS JOIN LATERAL(VALUES
        (60::NUMERIC,source.min_60_price),(100::NUMERIC,source.min_100_price),
        (150::NUMERIC,source.min_150_price)) tier(pack_qty,pack_price)
      JOIN public.product_uoms product_uom ON product_uom.company_id=v_company
        AND product_uom.product_id=source.product_id
        AND product_uom.is_active AND product_uom.sales_allowed
      WHERE tier.pack_price IS NOT NULL
    ) rules;
    v_save_result:=private.acp5f_save_reusable_pricelist_with_rules_core(
      v_default.id,v_default.master_version,v_default.name,'GLOBAL',v_default.priority,
      TRUE,v_default.applies_all_stores,
      CASE WHEN v_default.applies_all_stores THEN ARRAY[]::UUID[] ELSE ARRAY(
        SELECT assignment.store_id FROM public.pricelist_store_assignments assignment
        WHERE assignment.company_id=v_company AND assignment.pricelist_id=v_default.id) END,
      v_default.valid_from,v_default.valid_until,TRUE,v_default.notes,v_rules);
    v_changed_pricelists:=v_changed_pricelists+1;
  END IF;

  v_result:=v_result||jsonb_build_object('mode','APPLY','replayed',FALSE,
    'appliedProductCount',v_changed_products,
    'appliedPricelistCount',v_changed_pricelists,'committedAt',clock_timestamp());
  INSERT INTO public.pricelist_import_runs(
    company_id,client_request_id,source_file_name,source_file_checksum,
    source_row_count,applied_product_count,applied_pricelist_count,
    result_snapshot,actor_id
  ) VALUES(v_company,p_client_request_id,btrim(p_source_file_name),
    lower(p_source_file_checksum),v_row_count,v_changed_products,
    v_changed_pricelists,v_result,v_actor);
  RETURN v_result;
END
$$;

REVOKE ALL ON FUNCTION public.process_distributor_pricelist_import(
  JSONB,TEXT,TEXT,UUID,BOOLEAN,TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.process_distributor_pricelist_import(
  JSONB,TEXT,TEXT,UUID,BOOLEAN,TEXT) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260824110000','distributor_pricelist_missing_sku_skip',
  'Forward fix: unmatched SKU is reported as SKIPPED while matched valid rows remain atomically importable');

COMMIT;

