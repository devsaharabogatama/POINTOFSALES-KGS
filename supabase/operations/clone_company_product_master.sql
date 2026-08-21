-- Controlled Product master clone between Companies.
-- Default mode is PREVIEW and performs no persistent writes.
-- Run Finance clone first because Tax versions resolve target COA identities.

DROP TABLE IF EXISTS pg_temp.kgs_product_clone_config;
CREATE TEMP TABLE kgs_product_clone_config(
    source_company_id UUID,
    source_company_name TEXT,
    target_company_id UUID,
    target_company_name TEXT,
    actor_id UUID,
    execute_clone BOOLEAN NOT NULL,
    confirmation TEXT
);

INSERT INTO kgs_product_clone_config VALUES(
    NULL,             -- source Company UUID
    'KGS Company',    -- exact source company_name
    NULL,             -- target Company UUID
    NULL,             -- exact target company_name
    NULL,             -- optional; NULL selects linked Super Admin
    FALSE,            -- FALSE = PREVIEW, TRUE = APPLY
    NULL              -- APPLY requires: CLONE_PRODUCT_MASTER
);

DROP TABLE IF EXISTS pg_temp.kgs_product_clone_result;
CREATE TEMP TABLE kgs_product_clone_result(
    check_name TEXT NOT NULL,
    status TEXT NOT NULL,
    details JSONB NOT NULL
);

DROP TABLE IF EXISTS pg_temp.kgs_clone_category_map;
CREATE TEMP TABLE kgs_clone_category_map(source_id UUID PRIMARY KEY,target_id UUID UNIQUE NOT NULL);
DROP TABLE IF EXISTS pg_temp.kgs_clone_uom_map;
CREATE TEMP TABLE kgs_clone_uom_map(source_id UUID PRIMARY KEY,target_id UUID UNIQUE NOT NULL);
DROP TABLE IF EXISTS pg_temp.kgs_clone_tax_map;
CREATE TEMP TABLE kgs_clone_tax_map(source_id UUID PRIMARY KEY,target_id UUID UNIQUE NOT NULL);
DROP TABLE IF EXISTS pg_temp.kgs_clone_product_map;
CREATE TEMP TABLE kgs_clone_product_map(source_id UUID PRIMARY KEY,target_id UUID UNIQUE NOT NULL);
DROP TABLE IF EXISTS pg_temp.kgs_clone_product_uom_map;
CREATE TEMP TABLE kgs_clone_product_uom_map(source_id UUID PRIMARY KEY,target_id UUID UNIQUE NOT NULL);
DROP TABLE IF EXISTS pg_temp.kgs_clone_pricelist_map;
CREATE TEMP TABLE kgs_clone_pricelist_map(source_id UUID PRIMARY KEY,target_id UUID UNIQUE NOT NULL);
DROP TABLE IF EXISTS pg_temp.kgs_clone_pricelist_before;
CREATE TEMP TABLE kgs_clone_pricelist_before(target_id UUID PRIMARY KEY,before_state JSONB NOT NULL);

DO $operation$
DECLARE
    v_config pg_temp.kgs_product_clone_config%ROWTYPE;
    v_source public.companies%ROWTYPE;
    v_target public.companies%ROWTYPE;
    v_actor UUID;
    v_count BIGINT;
BEGIN
    SELECT * INTO STRICT v_config FROM pg_temp.kgs_product_clone_config;
    IF v_config.source_company_id IS NULL OR v_config.target_company_id IS NULL
       OR NULLIF(btrim(v_config.source_company_name),'') IS NULL
       OR NULLIF(btrim(v_config.target_company_name),'') IS NULL THEN
        RAISE EXCEPTION 'CONFIG_REQUIRED';
    END IF;
    IF v_config.source_company_id=v_config.target_company_id THEN
        RAISE EXCEPTION 'SOURCE_AND_TARGET_COMPANY_MUST_DIFFER';
    END IF;
    SELECT * INTO v_source FROM public.companies WHERE id=v_config.source_company_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'SOURCE_COMPANY_NOT_FOUND'; END IF;
    SELECT * INTO v_target FROM public.companies WHERE id=v_config.target_company_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'TARGET_COMPANY_NOT_FOUND'; END IF;
    IF btrim(v_source.company_name) IS DISTINCT FROM btrim(v_config.source_company_name) THEN
        RAISE EXCEPTION 'SOURCE_COMPANY_NAME_MISMATCH: %',v_source.company_name;
    END IF;
    IF btrim(v_target.company_name) IS DISTINCT FROM btrim(v_config.target_company_name) THEN
        RAISE EXCEPTION 'TARGET_COMPANY_NAME_MISMATCH: %',v_target.company_name;
    END IF;
    IF v_target.status<>'ACTIVE' THEN RAISE EXCEPTION 'TARGET_COMPANY_MUST_BE_ACTIVE'; END IF;

    v_actor:=v_config.actor_id;
    IF v_actor IS NULL THEN
        SELECT profile.id INTO v_actor FROM public.profiles profile
        WHERE public.private_is_super_admin(profile.id)
        ORDER BY profile.id LIMIT 1;
    END IF;
    IF v_actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=v_actor) THEN
        RAISE EXCEPTION 'VALID_AUDIT_ACTOR_REQUIRED';
    END IF;
    IF NOT public.private_is_super_admin(v_actor) AND NOT (
        EXISTS(SELECT 1 FROM public.company_memberships
               WHERE company_id=v_source.id AND user_id=v_actor AND status='ACTIVE'
                 AND role_code IN('COMPANY_OWNER','COMPANY_ADMIN'))
        AND EXISTS(SELECT 1 FROM public.company_memberships
                   WHERE company_id=v_target.id AND user_id=v_actor AND status='ACTIVE'
                     AND role_code IN('COMPANY_OWNER','COMPANY_ADMIN'))
    ) THEN RAISE EXCEPTION 'CLONE_ACTOR_MUST_CONTROL_BOTH_COMPANIES'; END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended('CLONE_PRODUCT|'||v_source.id::TEXT,0));
    PERFORM pg_advisory_xact_lock(hashtextextended('CLONE_PRODUCT|'||v_target.id::TEXT,0));

    SELECT
        (SELECT count(*) FROM public.sales_headers WHERE company_id=v_target.id)+
        (SELECT count(*) FROM public.financial_events WHERE company_id=v_target.id)+
        (SELECT count(*) FROM public.finance_journals WHERE company_id=v_target.id)+
        (SELECT count(*) FROM public.stock_movements WHERE company_id=v_target.id)+
        (SELECT count(*) FROM public.supplier_order_documents WHERE company_id=v_target.id)
    INTO v_count;
    INSERT INTO pg_temp.kgs_product_clone_result VALUES(
        'target_operational_history',CASE WHEN v_count=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('rowCount',v_count));

    SELECT
        (SELECT count(*) FROM public.products WHERE company_id=v_target.id)+
        (SELECT count(*) FROM public.product_uoms WHERE company_id=v_target.id)+
        (SELECT count(*) FROM public.product_bundle_items WHERE company_id=v_target.id)+
        (SELECT count(*) FROM public.product_categories WHERE company_id=v_target.id)+
        (SELECT count(*) FROM public.uoms WHERE company_id=v_target.id)
    INTO v_count;
    INSERT INTO pg_temp.kgs_product_clone_result VALUES(
        'target_product_master_empty',CASE WHEN v_count=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('rowCount',v_count));

    SELECT count(*) INTO v_count FROM public.tax_rules WHERE company_id=v_target.id;
    INSERT INTO pg_temp.kgs_product_clone_result VALUES(
        'target_tax_master_empty',CASE WHEN v_count=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('taxRuleRows',v_count));

    SELECT count(*) INTO v_count
    FROM public.pricelists source_row
    WHERE source_row.company_id=v_source.id AND source_row.scope='GLOBAL'
      AND NOT EXISTS(
          SELECT 1 FROM public.pricelists target_row
          WHERE target_row.company_id=v_target.id AND target_row.scope='GLOBAL'
            AND upper(regexp_replace(btrim(target_row.code),'\s+',' ','g'))=
                upper(regexp_replace(btrim(source_row.code),'\s+',' ','g')));
    INSERT INTO pg_temp.kgs_product_clone_result VALUES(
        'target_global_pricelist_identity',
        CASE WHEN v_count=0 AND
          (SELECT count(*) FROM public.pricelists WHERE company_id=v_source.id AND scope='GLOBAL')=
          (SELECT count(*) FROM public.pricelists WHERE company_id=v_target.id AND scope='GLOBAL')
        THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('unmatchedSourcePricelists',v_count,
          'sourceGlobalCount',(SELECT count(*) FROM public.pricelists
                               WHERE company_id=v_source.id AND scope='GLOBAL'),
          'targetGlobalCount',(SELECT count(*) FROM public.pricelists
                               WHERE company_id=v_target.id AND scope='GLOBAL'),
          'reason','Company baseline Pricelist is reused by normalized code'));

    SELECT count(*) INTO v_count FROM public.pricelist_rules
    WHERE company_id=v_target.id;
    INSERT INTO pg_temp.kgs_product_clone_result VALUES(
        'target_pricelist_rule_state',CASE WHEN v_count=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('ruleRows',v_count));

    SELECT count(*) INTO v_count FROM public.pricelists
    WHERE company_id=v_source.id AND scope='GLOBAL' AND NOT applies_all_stores;
    INSERT INTO pg_temp.kgs_product_clone_result VALUES(
        'source_store_scoped_global_pricelist',
        CASE WHEN v_count=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('rowCount',v_count,
          'reason','Store identities are intentionally not cloned'));

    SELECT count(*) INTO v_count
    FROM public.tax_rule_versions version
    JOIN public.chart_of_accounts source_account
      ON source_account.company_id=version.company_id AND source_account.id=version.account_id
    WHERE version.company_id=v_source.id AND version.status='ACTIVE'
      AND version.effective_from<=clock_timestamp()
      AND (version.effective_to IS NULL OR version.effective_to>clock_timestamp())
      AND NOT EXISTS(
        SELECT 1 FROM public.chart_of_accounts target_account
        WHERE target_account.company_id=v_target.id AND (
          (source_account.is_system_account AND target_account.is_system_account
           AND target_account.system_function_key=source_account.system_function_key)
          OR upper(regexp_replace(btrim(target_account.account_code),'\s+',' ','g'))=
             upper(regexp_replace(btrim(source_account.account_code),'\s+',' ','g'))));
    INSERT INTO pg_temp.kgs_product_clone_result VALUES(
        'target_tax_account_mapping',CASE WHEN v_count=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('unresolvedRows',v_count));

    INSERT INTO pg_temp.kgs_product_clone_result VALUES(
        'operation_mode',CASE WHEN v_config.execute_clone THEN 'APPLY' ELSE 'PREVIEW' END,
        jsonb_build_object('writesRequested',v_config.execute_clone,'actorId',v_actor,
          'sourceCompany',v_source.company_name,'targetCompany',v_target.company_name));

    IF EXISTS(SELECT 1 FROM pg_temp.kgs_product_clone_result WHERE status='BLOCKER') THEN
        IF v_config.execute_clone THEN RAISE EXCEPTION 'PRODUCT_CLONE_BLOCKED'; END IF;
        RETURN;
    END IF;
    IF NOT v_config.execute_clone THEN RETURN; END IF;
    IF v_config.confirmation IS DISTINCT FROM 'CLONE_PRODUCT_MASTER' THEN
        RAISE EXCEPTION 'APPLY_CONFIRMATION_REQUIRED: CLONE_PRODUCT_MASTER';
    END IF;

    INSERT INTO pg_temp.kgs_clone_category_map(source_id,target_id)
    SELECT id,gen_random_uuid() FROM public.product_categories WHERE company_id=v_source.id;
    INSERT INTO pg_temp.kgs_clone_uom_map(source_id,target_id)
    SELECT id,gen_random_uuid() FROM public.uoms WHERE company_id=v_source.id;
    INSERT INTO pg_temp.kgs_clone_tax_map(source_id,target_id)
    SELECT id,gen_random_uuid() FROM public.tax_rules WHERE company_id=v_source.id;
    INSERT INTO pg_temp.kgs_clone_product_map(source_id,target_id)
    SELECT id,gen_random_uuid() FROM public.products WHERE company_id=v_source.id;
    INSERT INTO pg_temp.kgs_clone_product_uom_map(source_id,target_id)
    SELECT id,gen_random_uuid() FROM public.product_uoms WHERE company_id=v_source.id;
    INSERT INTO pg_temp.kgs_clone_pricelist_map(source_id,target_id)
    SELECT source_row.id,target_row.id
    FROM public.pricelists source_row
    JOIN public.pricelists target_row
      ON target_row.company_id=v_target.id AND target_row.scope='GLOBAL'
     AND upper(regexp_replace(btrim(target_row.code),'\s+',' ','g'))=
         upper(regexp_replace(btrim(source_row.code),'\s+',' ','g'))
    WHERE source_row.company_id=v_source.id AND source_row.scope='GLOBAL';
    INSERT INTO pg_temp.kgs_clone_pricelist_before(target_id,before_state)
    SELECT target_row.id,to_jsonb(target_row)
    FROM pg_temp.kgs_clone_pricelist_map map
    JOIN public.pricelists target_row
      ON target_row.company_id=v_target.id AND target_row.id=map.target_id;

    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name,is_active,created_by,updated_by)
    SELECT map.target_id,v_target.id,source_row.category_code,source_row.category_name,
           source_row.is_active,v_actor,v_actor
    FROM public.product_categories source_row
    JOIN pg_temp.kgs_clone_category_map map ON map.source_id=source_row.id;

    INSERT INTO public.inventory_master_write_audit(
        company_id,master_type,master_id,actor_id,action,after_state)
    SELECT v_target.id,'PRODUCT_CATEGORY',target_row.id,v_actor,'CREATE',to_jsonb(target_row)
    FROM public.product_categories target_row
    WHERE target_row.company_id=v_target.id;

    INSERT INTO public.uoms(
        id,company_id,code,name,uom_type,allow_decimal,decimal_precision,
        is_active,created_by,updated_by)
    SELECT map.target_id,v_target.id,source_row.code,source_row.name,source_row.uom_type,
           source_row.allow_decimal,source_row.decimal_precision,source_row.is_active,v_actor,v_actor
    FROM public.uoms source_row JOIN pg_temp.kgs_clone_uom_map map ON map.source_id=source_row.id;

    INSERT INTO public.inventory_master_write_audit(
        company_id,master_type,master_id,actor_id,action,after_state)
    SELECT v_target.id,'UOM',target_row.id,v_actor,'CREATE',to_jsonb(target_row)
    FROM public.uoms target_row WHERE target_row.company_id=v_target.id;

    INSERT INTO public.tax_rules(
        id,company_id,tax_code,tax_name,tax_scope,is_active,created_by,updated_by)
    SELECT map.target_id,v_target.id,source_row.tax_code,source_row.tax_name,
           source_row.tax_scope,source_row.is_active,v_actor,v_actor
    FROM public.tax_rules source_row JOIN pg_temp.kgs_clone_tax_map map ON map.source_id=source_row.id;

    INSERT INTO public.tax_master_audit(
        company_id,entity_type,entity_id,action,actor_id,after_state)
    SELECT v_target.id,'TAX_RULE',target_row.id,'CREATE',v_actor,to_jsonb(target_row)
    FROM public.tax_rules target_row WHERE target_row.company_id=v_target.id;

    INSERT INTO public.tax_rule_versions(
        company_id,tax_rule_id,rate_percent,calculation_scope,default_price_mode,
        account_function_key,account_id,is_recoverable,effective_from,effective_to,
        rule_version,status,approved_by,approved_at,created_by,updated_by)
    SELECT v_target.id,tax_map.target_id,version.rate_percent,version.calculation_scope,
           version.default_price_mode,version.account_function_key,target_account.id,
           version.is_recoverable,version.effective_from,version.effective_to,
           version.rule_version,version.status,
           CASE WHEN version.status='ACTIVE' THEN v_actor END,
           CASE WHEN version.status='ACTIVE' THEN clock_timestamp() END,v_actor,v_actor
    FROM public.tax_rule_versions version
    JOIN pg_temp.kgs_clone_tax_map tax_map ON tax_map.source_id=version.tax_rule_id
    JOIN public.chart_of_accounts source_account
      ON source_account.company_id=v_source.id AND source_account.id=version.account_id
    JOIN LATERAL(
        SELECT account.id FROM public.chart_of_accounts account
        WHERE account.company_id=v_target.id AND (
          (source_account.is_system_account AND account.is_system_account
           AND account.system_function_key=source_account.system_function_key)
          OR upper(regexp_replace(btrim(account.account_code),'\s+',' ','g'))=
             upper(regexp_replace(btrim(source_account.account_code),'\s+',' ','g')))
        ORDER BY CASE WHEN source_account.is_system_account
                           AND account.system_function_key=source_account.system_function_key
                      THEN 0 ELSE 1 END,account.id LIMIT 1
    ) target_account ON TRUE
    WHERE version.company_id=v_source.id AND version.status='ACTIVE'
      AND version.effective_from<=clock_timestamp()
      AND (version.effective_to IS NULL OR version.effective_to>clock_timestamp());

    INSERT INTO public.tax_master_audit(
        company_id,entity_type,entity_id,action,actor_id,after_state)
    SELECT v_target.id,'TAX_RULE_VERSION',version.id,'CREATE',v_actor,to_jsonb(version)
    FROM public.tax_rule_versions version WHERE version.company_id=v_target.id;

    UPDATE public.product_categories target_row SET
        default_sales_tax_rule_id=sales_tax.target_id,
        default_purchase_tax_rule_id=purchase_tax.target_id,
        updated_by=v_actor
    FROM public.product_categories source_row
    JOIN pg_temp.kgs_clone_category_map category_map ON category_map.source_id=source_row.id
    LEFT JOIN pg_temp.kgs_clone_tax_map sales_tax ON sales_tax.source_id=source_row.default_sales_tax_rule_id
    LEFT JOIN pg_temp.kgs_clone_tax_map purchase_tax ON purchase_tax.source_id=source_row.default_purchase_tax_rule_id
    WHERE target_row.company_id=v_target.id AND target_row.id=category_map.target_id;

    INSERT INTO public.products(
        id,company_id,sku,name,category,vendor,merk,price,cogs,uom,uom_id,
        weight_per_uom_kg,is_bundle,is_active,image_url,category_id,
        weight_reference_uom_id,sales_tax_rule_id,purchase_tax_rule_id,
        created_by,updated_by)
    SELECT product_map.target_id,v_target.id,source_row.sku,source_row.name,
        source_row.category,source_row.vendor,source_row.merk,source_row.price,
        source_row.cogs,source_row.uom,base_uom.target_id,
        source_row.weight_per_uom_kg,source_row.is_bundle,source_row.is_active,
        source_row.image_url,category_map.target_id,weight_uom.target_id,
        sales_tax.target_id,purchase_tax.target_id,v_actor,v_actor
    FROM public.products source_row
    JOIN pg_temp.kgs_clone_product_map product_map ON product_map.source_id=source_row.id
    JOIN pg_temp.kgs_clone_category_map category_map ON category_map.source_id=source_row.category_id
    JOIN pg_temp.kgs_clone_uom_map base_uom ON base_uom.source_id=source_row.uom_id
    JOIN pg_temp.kgs_clone_uom_map weight_uom ON weight_uom.source_id=source_row.weight_reference_uom_id
    LEFT JOIN pg_temp.kgs_clone_tax_map sales_tax ON sales_tax.source_id=source_row.sales_tax_rule_id
    LEFT JOIN pg_temp.kgs_clone_tax_map purchase_tax ON purchase_tax.source_id=source_row.purchase_tax_rule_id
    WHERE source_row.company_id=v_source.id;

    INSERT INTO public.product_uoms(
        id,company_id,product_id,uom_id,factor_to_base,purchase_allowed,
        sales_allowed,purchase_price,sale_price,barcode,is_active,
        conversion_version,effective_from,created_by,updated_by)
    SELECT product_uom_map.target_id,v_target.id,product_map.target_id,uom_map.target_id,
        source_row.factor_to_base,source_row.purchase_allowed,source_row.sales_allowed,
        source_row.purchase_price,source_row.sale_price,source_row.barcode,
        source_row.is_active,source_row.conversion_version,source_row.effective_from,
        v_actor,v_actor
    FROM public.product_uoms source_row
    JOIN pg_temp.kgs_clone_product_uom_map product_uom_map ON product_uom_map.source_id=source_row.id
    JOIN pg_temp.kgs_clone_product_map product_map ON product_map.source_id=source_row.product_id
    JOIN pg_temp.kgs_clone_uom_map uom_map ON uom_map.source_id=source_row.uom_id
    WHERE source_row.company_id=v_source.id;

    INSERT INTO public.product_master_audit(
        company_id,product_id,action,actor_id,after_snapshot)
    SELECT v_target.id,target_row.id,'CREATE',v_actor,to_jsonb(target_row)
    FROM public.products target_row WHERE target_row.company_id=v_target.id;

    INSERT INTO public.product_bundle_items(
        company_id,bundle_id,item_id,qty,component_uom_id,component_qty,
        line_no,created_by,updated_by)
    SELECT v_target.id,bundle_map.target_id,item_map.target_id,source_row.component_qty,
        uom_map.target_id,source_row.component_qty,source_row.line_no,v_actor,v_actor
    FROM public.product_bundle_items source_row
    JOIN pg_temp.kgs_clone_product_map bundle_map ON bundle_map.source_id=source_row.bundle_id
    JOIN pg_temp.kgs_clone_product_map item_map ON item_map.source_id=source_row.item_id
    JOIN pg_temp.kgs_clone_uom_map uom_map ON uom_map.source_id=source_row.component_uom_id
    WHERE source_row.company_id=v_source.id;

    INSERT INTO public.product_bundle_master_audit(
        company_id,bundle_id,action,actor_id,after_snapshot)
    SELECT v_target.id,map.target_id,'CREATE',v_actor,
      jsonb_build_object('product',to_jsonb(product),
        'components',COALESCE((SELECT jsonb_agg(to_jsonb(item) ORDER BY item.line_no)
          FROM public.product_bundle_items item
          WHERE item.company_id=v_target.id AND item.bundle_id=map.target_id),'[]'::JSONB))
    FROM pg_temp.kgs_clone_product_map map
    JOIN public.products product ON product.company_id=v_target.id AND product.id=map.target_id
    JOIN public.products source_product ON source_product.id=map.source_id
    WHERE source_product.company_id=v_source.id AND source_product.is_bundle;

    UPDATE public.pricelists target_row SET
        name=source_row.name,priority=source_row.priority,
        is_default=source_row.is_default,applies_all_stores=TRUE,
        valid_from=source_row.valid_from,valid_until=source_row.valid_until,
        is_active=source_row.is_active,notes=source_row.notes,updated_by=v_actor
    FROM public.pricelists source_row
    JOIN pg_temp.kgs_clone_pricelist_map map ON map.source_id=source_row.id
    WHERE target_row.company_id=v_target.id AND target_row.id=map.target_id;

    INSERT INTO public.pricelist_rules(
        company_id,pricelist_id,product_id,product_uom_id,min_qty,tier_qty_basis,
        pricing_method,fixed_unit_price,discount_amount_per_unit,discount_percent,
        valid_from,valid_until,is_active,rule_version,created_by,updated_by)
    SELECT v_target.id,pricelist_map.target_id,product_map.target_id,
        product_uom_map.target_id,source_row.min_qty,source_row.tier_qty_basis,
        source_row.pricing_method,source_row.fixed_unit_price,
        source_row.discount_amount_per_unit,source_row.discount_percent,
        source_row.valid_from,source_row.valid_until,source_row.is_active,
        source_row.rule_version,v_actor,v_actor
    FROM public.pricelist_rules source_row
    JOIN pg_temp.kgs_clone_pricelist_map pricelist_map ON pricelist_map.source_id=source_row.pricelist_id
    JOIN pg_temp.kgs_clone_product_map product_map ON product_map.source_id=source_row.product_id
    JOIN pg_temp.kgs_clone_product_uom_map product_uom_map ON product_uom_map.source_id=source_row.product_uom_id
    WHERE source_row.company_id=v_source.id;

    INSERT INTO public.pricelist_master_audit(
        company_id,pricelist_id,action,actor_id,before_state,after_state)
    SELECT v_target.id,target_row.id,'UPDATE',v_actor,before.before_state,
      to_jsonb(target_row)||jsonb_build_object(
        'cloneSourceCompanyId',v_source.id,'cloneSourcePricelistId',map.source_id,
        'ruleCount',(SELECT count(*) FROM public.pricelist_rules rule
          WHERE rule.company_id=v_target.id AND rule.pricelist_id=target_row.id))
    FROM pg_temp.kgs_clone_pricelist_map map
    JOIN public.pricelists target_row
      ON target_row.company_id=v_target.id AND target_row.id=map.target_id
    JOIN pg_temp.kgs_clone_pricelist_before before
      ON before.target_id=target_row.id;

    IF (SELECT count(*) FROM public.product_categories WHERE company_id=v_target.id)
       <> (SELECT count(*) FROM public.product_categories WHERE company_id=v_source.id)
       OR (SELECT count(*) FROM public.uoms WHERE company_id=v_target.id)
       <> (SELECT count(*) FROM public.uoms WHERE company_id=v_source.id)
       OR (SELECT count(*) FROM public.products WHERE company_id=v_target.id)
       <> (SELECT count(*) FROM public.products WHERE company_id=v_source.id)
       OR (SELECT count(*) FROM public.product_uoms WHERE company_id=v_target.id)
       <> (SELECT count(*) FROM public.product_uoms WHERE company_id=v_source.id)
       OR (SELECT count(*) FROM public.product_bundle_items WHERE company_id=v_target.id)
       <> (SELECT count(*) FROM public.product_bundle_items WHERE company_id=v_source.id)
       OR (SELECT count(*) FROM public.tax_rules WHERE company_id=v_target.id)
       <> (SELECT count(*) FROM public.tax_rules WHERE company_id=v_source.id)
       OR (SELECT count(*) FROM public.pricelist_rules WHERE company_id=v_target.id)
       <> (SELECT count(*) FROM public.pricelist_rules rule
           JOIN public.pricelists pricelist
             ON pricelist.company_id=rule.company_id AND pricelist.id=rule.pricelist_id
           WHERE rule.company_id=v_source.id AND pricelist.scope='GLOBAL') THEN
        RAISE EXCEPTION 'PRODUCT_CLONE_COUNT_VERIFICATION_FAILED';
    END IF;
    IF EXISTS(
        SELECT 1 FROM public.products product
        WHERE product.company_id=v_target.id AND (
          NOT EXISTS(SELECT 1 FROM public.product_categories category
                     WHERE category.company_id=v_target.id AND category.id=product.category_id)
          OR NOT EXISTS(SELECT 1 FROM public.product_uoms product_uom
                        WHERE product_uom.company_id=v_target.id
                          AND product_uom.product_id=product.id
                          AND product_uom.uom_id=product.uom_id
                          AND product_uom.factor_to_base=1))) THEN
        RAISE EXCEPTION 'PRODUCT_CLONE_DEPENDENCY_VERIFICATION_FAILED';
    END IF;
    IF EXISTS(SELECT 1 FROM public.product_stocks WHERE company_id=v_target.id)
       OR EXISTS(SELECT 1 FROM public.product_batches WHERE company_id=v_target.id)
       OR EXISTS(SELECT 1 FROM public.stock_movements WHERE company_id=v_target.id) THEN
        RAISE EXCEPTION 'PRODUCT_CLONE_UNEXPECTED_STOCK_EFFECT';
    END IF;

    INSERT INTO pg_temp.kgs_product_clone_result VALUES(
        'clone_result','APPLIED',jsonb_build_object(
          'categories',(SELECT count(*) FROM pg_temp.kgs_clone_category_map),
          'uoms',(SELECT count(*) FROM pg_temp.kgs_clone_uom_map),
          'taxRules',(SELECT count(*) FROM pg_temp.kgs_clone_tax_map),
          'products',(SELECT count(*) FROM pg_temp.kgs_clone_product_map),
          'productUoms',(SELECT count(*) FROM pg_temp.kgs_clone_product_uom_map),
          'bundleItems',(SELECT count(*) FROM public.product_bundle_items WHERE company_id=v_target.id),
          'pricelistRules',(SELECT count(*) FROM public.pricelist_rules WHERE company_id=v_target.id)));
END
$operation$;

SELECT check_name,status,details
FROM pg_temp.kgs_product_clone_result
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'APPLIED' THEN 2
                     WHEN 'PASS' THEN 3 WHEN 'PREVIEW' THEN 4 ELSE 5 END,
         check_name;
