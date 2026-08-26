-- Controlled COGS-only master-data update from:
--   Price List Distributor 26082026.xlsx
-- SHA-256:
--   c3d3385935a3b6270c22d43dc9aae2844bc35b837f50ad19e028f99617f33218
--
-- SAFETY CONTRACT
-- - one Company per run;
-- - default PREVIEW performs no persistent write;
-- - source COGS is the price of one PACK;
-- - only products.cogs and active product_uoms.purchase_price may change;
-- - inactive UOM, Retail, sale price, Pricelist, Product identity, Stock, FIFO,
--   transaction snapshots, Financial Event and Journal are never changed;
-- - unmatched SKU is reported as SKIPPED;
-- - Product/PACK ambiguity is a BLOCKER;
-- - APPLY is atomic and writes product_master_audit only for changed Product.
--
-- HOW TO RUN
-- 1. Set target_company_identifier to LSM, SMS, or KMS.
-- 2. Keep execute_change=FALSE and run the WHOLE file.
-- 3. APPLY only when every BLOCKER row is PASS and skipped SKU is accepted.
-- 4. Set execute_change=TRUE and confirmation=UPDATE_COMPANY_COGS_20260826.
-- 5. Run the WHOLE file again, then restore execute_change=FALSE.

BEGIN;

DROP TABLE IF EXISTS pg_temp.kgs_cogs_update_config;
DROP TABLE IF EXISTS pg_temp.kgs_cogs_update_source;
DROP TABLE IF EXISTS pg_temp.kgs_cogs_update_target;
DROP TABLE IF EXISTS pg_temp.kgs_cogs_update_plan;
DROP TABLE IF EXISTS pg_temp.kgs_cogs_update_result;

CREATE TEMP TABLE kgs_cogs_update_config(
    target_company_identifier TEXT NOT NULL,
    actor_email TEXT,
    execute_change BOOLEAN NOT NULL,
    confirmation TEXT NOT NULL,
    source_file_name TEXT NOT NULL,
    source_file_sha256 TEXT NOT NULL
) ON COMMIT PRESERVE ROWS;

INSERT INTO kgs_cogs_update_config(
    target_company_identifier,actor_email,execute_change,confirmation,
    source_file_name,source_file_sha256
) VALUES (
    'LSM', -- ganti per run: LSM, SMS, lalu KMS
    NULL,  -- optional: email actor; NULL memilih Owner/Admin lalu Super Admin
    FALSE, -- FALSE=PREVIEW; TRUE=APPLY
    '',    -- APPLY wajib: UPDATE_COMPANY_COGS_20260826
    'Price List Distributor 26082026.xlsx',
    'c3d3385935a3b6270c22d43dc9aae2844bc35b837f50ad19e028f99617f33218'
);

CREATE TEMP TABLE kgs_cogs_update_source(
    row_number INTEGER PRIMARY KEY,
    source_sku TEXT NOT NULL,
    normalized_sku TEXT NOT NULL,
    source_product_name TEXT NOT NULL,
    cogs_per_pack NUMERIC(20,4) NOT NULL CHECK(cogs_per_pack>=0),
    UNIQUE(normalized_sku)
) ON COMMIT PRESERVE ROWS;

INSERT INTO kgs_cogs_update_source(
    row_number,source_sku,normalized_sku,source_product_name,cogs_per_pack
)
SELECT row_number,sku,
       upper(regexp_replace(btrim(sku),'\s+',' ','g')),
       product_name,cogs
FROM (VALUES
    (3, 'T16B', 'Tortilla 16 Bidayah', 14630),
    (4, 'T17B', 'Tortilla 17 Bidayah', 14630),
    (5, 'T19B', 'Tortilla 19 Bidayah', 17330),
    (6, 'T20B', 'Tortilla 20 Bidayah', 17330),
    (7, 'T22B', 'Tortilla 22 Bidayah', 20983),
    (8, 'T23B', 'Tortilla 23 Bidayah', 20983),
    (9, 'T24B', 'Tortilla 24 Bidayah', 22948),
    (10, 'T25B', 'Tortilla 25 Bidayah', 22948),
    (11, 'T26B', 'Tortilla 26 Bidayah', 24811),
    (12, 'T27B', 'Tortilla 27 Bidayah', 24811),
    (13, 'T16BC', 'Tortilla 16 Bidayah Crispy', 14855),
    (14, 'T17BC', 'Tortilla 17 Bidayah Crispy', 14855),
    (15, 'T19BC', 'Tortilla 19 Bidayah Crispy', 17631),
    (16, 'T20BC', 'Tortilla 20 Bidayah Crispy', 17631),
    (17, 'T22BC', 'Tortilla 22 Bidayah Crispy', 21397),
    (18, 'T23BC', 'Tortilla 23 Bidayah Crispy', 21397),
    (19, 'T24BC', 'Tortilla 24 Bidayah Crispy', 23437),
    (20, 'T25BC', 'Tortilla 25 Bidayah Crispy', 23437),
    (21, 'T26BC', 'Tortilla 26 Bidayah Crispy', 25363),
    (22, 'T27BC', 'Tortilla 27 Bidayah Crispy', 25363),
    (23, 'T16B10', 'Tortilla 16 Bidayah ISI 10', 14944),
    (24, 'T17B10', 'Tortilla 17 Bidayah ISI 10', 14944),
    (25, 'T19B10', 'Tortilla 19 Bidayah ISI 10', 17609),
    (26, 'T20B10', 'Tortilla 20 Bidayah ISI 10', 17609),
    (27, 'T22B10', 'Tortilla 22 Bidayah ISI 10', 21157),
    (28, 'T23B10', 'Tortilla 23 Bidayah ISI 10', 21157),
    (29, 'T24B10', 'Tortilla 24 Bidayah ISI 10', 23122),
    (30, 'T25B10', 'Tortilla 25 Bidayah ISI 10', 23122),
    (31, 'T26B10', 'Tortilla 26 Bidayah ISI 10', 24959),
    (32, 'T27B10', 'Tortilla 27 Bidayah ISI 10', 24959),
    (33, 'T16BB', 'Tortilla 16 Bidayah Black', 16294),
    (34, 'T17BB', 'Tortilla 17 Bidayah Black', 16294),
    (35, 'T19BB', 'Tortilla 19 Bidayah Black', 19549),
    (36, 'T20BB', 'Tortilla 20 Bidayah Black', 19549),
    (37, 'T22BB', 'Tortilla 22 Bidayah Black', 24035),
    (38, 'T23BB', 'Tortilla 23 Bidayah Black', 24035),
    (39, 'T24BB', 'Tortilla 24 Bidayah Black', 26555),
    (40, 'T25BB', 'Tortilla 25 Bidayah Black', 26555),
    (41, 'T26BB', 'Tortilla 26 Bidayah Black', 28880),
    (42, 'T27BB', 'Tortilla 27 Bidayah Black', 28880),
    (43, 'BRB6', 'Bidayah Roti Burger (ISI 6)', 7479),
    (44, 'BRBD6', 'Bidayah Roti Burger Bandung (ISI 6)', 7350),
    (45, 'BRBB6', 'Bidayah Roti Burger Belah (ISI 6)', 7479),
    (46, 'BRB10', 'Bidayah Roti Burger (ISI 10)', 13592),
    (47, 'BRB10-2', 'Bidayah Roti Burger (ISI 10) New', 13592)
) source(row_number,sku,product_name,cogs);

CREATE TEMP TABLE kgs_cogs_update_target ON COMMIT PRESERVE ROWS AS
SELECT company.id AS company_id,company.company_code,company.company_name,
       COALESCE(explicit_actor.id,company_actor.id,super_actor.id) AS actor_id,
       COALESCE(explicit_actor.email,company_actor.email,super_actor.email)
         AS actor_email
FROM kgs_cogs_update_config config
JOIN public.companies company
  ON (
    upper(btrim(company.company_code))=
      upper(btrim(config.target_company_identifier))
    OR company.id::TEXT=btrim(config.target_company_identifier)
  )
 AND company.status='ACTIVE'
LEFT JOIN LATERAL (
    SELECT profile.id,auth_user.email
    FROM auth.users auth_user
    JOIN public.profiles profile ON profile.id=auth_user.id
    WHERE config.actor_email IS NOT NULL
      AND lower(btrim(auth_user.email))=lower(btrim(config.actor_email))
      AND (
        profile.role::TEXT='super_admin'
        OR EXISTS(
          SELECT 1 FROM public.company_memberships membership
          WHERE membership.company_id=company.id
            AND membership.user_id=profile.id
            AND membership.status='ACTIVE'
            AND membership.role_code IN('COMPANY_OWNER','COMPANY_ADMIN')
        )
      )
    ORDER BY profile.id LIMIT 1
) explicit_actor ON TRUE
LEFT JOIN LATERAL (
    SELECT profile.id,profile.email
    FROM public.company_memberships membership
    JOIN public.profiles profile ON profile.id=membership.user_id
    WHERE config.actor_email IS NULL
      AND membership.company_id=company.id
      AND membership.status='ACTIVE'
      AND membership.role_code IN('COMPANY_OWNER','COMPANY_ADMIN')
    ORDER BY CASE membership.role_code WHEN 'COMPANY_OWNER' THEN 0 ELSE 1 END,
             profile.id
    LIMIT 1
) company_actor ON TRUE
LEFT JOIN LATERAL (
    SELECT profile.id,profile.email
    FROM public.profiles profile
    WHERE config.actor_email IS NULL AND profile.role::TEXT='super_admin'
    ORDER BY profile.id LIMIT 1
) super_actor ON TRUE;

CREATE TEMP TABLE kgs_cogs_update_plan ON COMMIT PRESERVE ROWS AS
SELECT source.row_number,source.source_sku,source.normalized_sku,
       source.source_product_name,source.cogs_per_pack,
       product.id AS product_id,product.name AS product_name,
       product.is_active AS product_is_active,product.is_bundle,
       product.cogs AS old_base_cogs,
       pack.product_uom_id AS pack_product_uom_id,
       pack.pack_factor,COALESCE(pack.pack_count,0) AS pack_count,
       CASE WHEN pack.pack_factor>0
            THEN round(source.cogs_per_pack/pack.pack_factor,4) END
         AS new_base_cogs,
       CASE
         WHEN product.id IS NULL THEN 'SKIPPED'
         WHEN NOT product.is_active THEN 'ERROR'
         WHEN product.is_bundle THEN 'ERROR'
         WHEN COALESCE(pack.pack_count,0)=0 THEN 'ERROR'
         WHEN pack.pack_count<>1 THEN 'ERROR'
         WHEN pack.pack_factor IS NULL OR pack.pack_factor<=0 THEN 'ERROR'
         ELSE 'VALID'
       END AS row_status,
       CASE
         WHEN product.id IS NULL THEN 'PRODUCT_SKU_NOT_FOUND'
         WHEN NOT product.is_active THEN 'PRODUCT_INACTIVE'
         WHEN product.is_bundle THEN 'BUNDLE_COGS_NOT_DIRECTLY_EDITABLE'
         WHEN COALESCE(pack.pack_count,0)=0 THEN 'ACTIVE_PACK_UOM_NOT_FOUND'
         WHEN pack.pack_count<>1 THEN 'AMBIGUOUS_ACTIVE_PACK_UOM'
         WHEN pack.pack_factor IS NULL OR pack.pack_factor<=0
           THEN 'INVALID_PACK_FACTOR'
       END AS issue_code,
       CASE WHEN product.id IS NOT NULL AND
         lower(regexp_replace(btrim(product.name),'\s+',' ','g'))<>
         lower(regexp_replace(btrim(source.source_product_name),'\s+',' ','g'))
         THEN 'SOURCE_NAME_DIFFERS' END AS warning_code
FROM kgs_cogs_update_source source
LEFT JOIN kgs_cogs_update_target target ON TRUE
LEFT JOIN public.products product
  ON product.company_id=target.company_id
 AND upper(regexp_replace(btrim(product.sku),'\s+',' ','g'))=
       source.normalized_sku
LEFT JOIN LATERAL (
    SELECT count(*)::INTEGER AS pack_count,
           min(product_uom.id::TEXT)::UUID AS product_uom_id,
           min(product_uom.factor_to_base) AS pack_factor
    FROM public.product_uoms product_uom
    JOIN public.uoms uom
      ON uom.company_id=product_uom.company_id
     AND uom.id=product_uom.uom_id
    WHERE product_uom.company_id=product.company_id
      AND product_uom.product_id=product.id
      AND product_uom.is_active
      AND (upper(btrim(uom.code))='PACK' OR upper(btrim(uom.name))='PACK')
) pack ON product.id IS NOT NULL;

CREATE TEMP TABLE kgs_cogs_update_result(
    check_name TEXT NOT NULL,
    status TEXT NOT NULL,
    details JSONB NOT NULL
) ON COMMIT PRESERVE ROWS;

DO $operation$
DECLARE
    v_config kgs_cogs_update_config%ROWTYPE;
    v_target kgs_cogs_update_target%ROWTYPE;
    v_target_count INTEGER;
    v_source_count INTEGER;
    v_duplicate_source INTEGER;
    v_valid_count INTEGER;
    v_skipped_count INTEGER;
    v_error_count INTEGER;
    v_changed_product_count INTEGER:=0;
    v_changed_uom_count INTEGER:=0;
    v_uom_change_count INTEGER:=0;
    v_verified_uom_count INTEGER:=0;
    v_before JSONB;
    v_after JSONB;
    v_row RECORD;
BEGIN
    SELECT * INTO STRICT v_config FROM kgs_cogs_update_config;
    SELECT count(*) INTO v_target_count FROM kgs_cogs_update_target;
    SELECT count(*) INTO v_source_count FROM kgs_cogs_update_source;
    SELECT count(*) INTO v_duplicate_source FROM (
      SELECT normalized_sku FROM kgs_cogs_update_source
      GROUP BY normalized_sku HAVING count(*)>1
    ) duplicate_row;

    INSERT INTO kgs_cogs_update_result VALUES(
      'target_company',CASE WHEN v_target_count=1 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object('requestedCompanyIdentifier',
        v_config.target_company_identifier,'matchedCompanies',v_target_count));

    INSERT INTO kgs_cogs_update_result VALUES(
      'source_file_contract',
      CASE WHEN v_source_count=45 AND v_duplicate_source=0
        AND (SELECT sum(cogs_per_pack) FROM kgs_cogs_update_source)=890470
        AND v_config.source_file_sha256=
          'c3d3385935a3b6270c22d43dc9aae2844bc35b837f50ad19e028f99617f33218'
        THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object('fileName',v_config.source_file_name,
        'sha256',v_config.source_file_sha256,'sourceRows',v_source_count,
        'cogsTotal',(SELECT sum(cogs_per_pack) FROM kgs_cogs_update_source),
        'duplicateSkuGroups',v_duplicate_source));

    IF v_target_count<>1 THEN
      IF v_config.execute_change THEN
        RAISE EXCEPTION 'TARGET_COMPANY_NOT_FOUND_OR_AMBIGUOUS: %',
          v_config.target_company_identifier;
      END IF;
      RETURN;
    END IF;
    SELECT * INTO STRICT v_target FROM kgs_cogs_update_target;

    INSERT INTO kgs_cogs_update_result VALUES(
      'audit_actor',CASE WHEN v_target.actor_id IS NOT NULL
        THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object('actorId',v_target.actor_id,
        'actorEmail',v_target.actor_email));

    SELECT count(*) FILTER(WHERE row_status='VALID'),
           count(*) FILTER(WHERE row_status='SKIPPED'),
           count(*) FILTER(WHERE row_status='ERROR')
    INTO v_valid_count,v_skipped_count,v_error_count
    FROM kgs_cogs_update_plan;

    INSERT INTO kgs_cogs_update_result VALUES(
      'product_pack_cogs_readiness',
      CASE WHEN v_valid_count>0 AND v_error_count=0 THEN 'PASS'
           ELSE 'BLOCKER' END,
      jsonb_build_object('validProducts',v_valid_count,
        'skippedSku',v_skipped_count,'errorRows',v_error_count,
        'errorSample',COALESCE((SELECT jsonb_agg(to_jsonb(sample)) FROM (
          SELECT row_number,source_sku,product_name,issue_code
          FROM kgs_cogs_update_plan WHERE row_status='ERROR'
          ORDER BY row_number LIMIT 20) sample),'[]'::JSONB)));

    INSERT INTO kgs_cogs_update_result VALUES(
      'unmatched_sku_scope','INFO',jsonb_build_object(
        'skippedCount',v_skipped_count,
        'skipped',COALESCE((SELECT jsonb_agg(to_jsonb(sample)) FROM (
          SELECT row_number,source_sku,source_product_name
          FROM kgs_cogs_update_plan WHERE row_status='SKIPPED'
          ORDER BY row_number) sample),'[]'::JSONB)));

    INSERT INTO kgs_cogs_update_result VALUES(
      'planned_cogs_effect','INFO',jsonb_build_object(
        'companyCode',v_target.company_code,'companyName',v_target.company_name,
        'productsEvaluated',v_valid_count,
        'productsChanging',(SELECT count(*) FROM kgs_cogs_update_plan plan
          WHERE plan.row_status='VALID'
            AND plan.old_base_cogs IS DISTINCT FROM plan.new_base_cogs),
        'activeProductUomsChanging',(SELECT count(*)
          FROM kgs_cogs_update_plan plan
          JOIN public.product_uoms product_uom
            ON product_uom.company_id=v_target.company_id
           AND product_uom.product_id=plan.product_id
           AND product_uom.is_active
          WHERE plan.row_status='VALID'
            AND product_uom.purchase_price IS DISTINCT FROM
              round(plan.new_base_cogs*product_uom.factor_to_base,4)),
        'historyRevalued',FALSE,'salesPriceChanged',FALSE));

    INSERT INTO kgs_cogs_update_result VALUES(
      'operation_mode',CASE WHEN v_config.execute_change THEN 'APPLY' ELSE 'PREVIEW' END,
      jsonb_build_object('writesExecuted',v_config.execute_change,
        'confirmationRequired','UPDATE_COMPANY_COGS_20260826'));

    IF NOT v_config.execute_change THEN RETURN; END IF;
    IF v_config.confirmation<>'UPDATE_COMPANY_COGS_20260826' THEN
      RAISE EXCEPTION 'CONFIRMATION_REQUIRED: UPDATE_COMPANY_COGS_20260826';
    END IF;
    IF v_target.actor_id IS NULL THEN RAISE EXCEPTION 'AUDIT_ACTOR_REQUIRED'; END IF;
    IF v_source_count<>45 OR v_duplicate_source<>0
       OR (SELECT sum(cogs_per_pack) FROM kgs_cogs_update_source)<>890470
       OR v_config.source_file_sha256<>
         'c3d3385935a3b6270c22d43dc9aae2844bc35b837f50ad19e028f99617f33218'
       OR v_error_count<>0
       OR v_valid_count=0 THEN
      RAISE EXCEPTION 'COGS_UPDATE_HAS_BLOCKER';
    END IF;

    -- Deterministic locks prevent concurrent Product edits from interleaving.
    PERFORM 1 FROM public.products product
    JOIN kgs_cogs_update_plan plan
      ON plan.product_id=product.id AND plan.row_status='VALID'
    WHERE product.company_id=v_target.company_id
    ORDER BY product.id FOR UPDATE OF product;

    PERFORM 1 FROM public.product_uoms product_uom
    JOIN kgs_cogs_update_plan plan
      ON plan.product_id=product_uom.product_id AND plan.row_status='VALID'
    WHERE product_uom.company_id=v_target.company_id
      AND product_uom.is_active
    ORDER BY product_uom.product_id,product_uom.id FOR UPDATE OF product_uom;

    -- Abort if Product/PACK shape changed after PREVIEW or while waiting for
    -- the deterministic locks. APPLY never continues with a stale conversion.
    IF EXISTS(
      SELECT 1 FROM kgs_cogs_update_plan plan
      JOIN public.products product
        ON product.company_id=v_target.company_id
       AND product.id=plan.product_id
      LEFT JOIN LATERAL (
        SELECT count(*)::INTEGER AS pack_count,
               min(product_uom.factor_to_base) AS pack_factor
        FROM public.product_uoms product_uom
        JOIN public.uoms uom
          ON uom.company_id=product_uom.company_id
         AND uom.id=product_uom.uom_id
        WHERE product_uom.company_id=product.company_id
          AND product_uom.product_id=product.id AND product_uom.is_active
          AND (upper(btrim(uom.code))='PACK'
               OR upper(btrim(uom.name))='PACK')
      ) current_pack ON TRUE
      WHERE plan.row_status='VALID'
        AND (NOT product.is_active OR product.is_bundle
          OR current_pack.pack_count<>1
          OR current_pack.pack_factor IS DISTINCT FROM plan.pack_factor)
    ) THEN
      RAISE EXCEPTION 'COGS_UPDATE_PLAN_STALE: rerun PREVIEW';
    END IF;

    FOR v_row IN
      SELECT * FROM kgs_cogs_update_plan
      WHERE row_status='VALID' ORDER BY product_id
    LOOP
      SELECT jsonb_build_object('product',to_jsonb(product),'uoms',COALESCE((
        SELECT jsonb_agg(to_jsonb(product_uom)
          ORDER BY product_uom.factor_to_base,product_uom.id)
        FROM public.product_uoms product_uom
        WHERE product_uom.company_id=v_target.company_id
          AND product_uom.product_id=v_row.product_id),'[]'::JSONB))
      INTO v_before FROM public.products product
      WHERE product.company_id=v_target.company_id
        AND product.id=v_row.product_id;

      UPDATE public.products product SET
        cogs=v_row.new_base_cogs,updated_by=v_target.actor_id
      WHERE product.company_id=v_target.company_id
        AND product.id=v_row.product_id
        AND product.cogs IS DISTINCT FROM v_row.new_base_cogs;
      IF FOUND THEN v_changed_product_count:=v_changed_product_count+1; END IF;

      WITH changed AS(
        UPDATE public.product_uoms product_uom SET
          purchase_price=round(v_row.new_base_cogs*product_uom.factor_to_base,4),
          updated_by=v_target.actor_id
        WHERE product_uom.company_id=v_target.company_id
          AND product_uom.product_id=v_row.product_id
          AND product_uom.is_active
          AND product_uom.purchase_price IS DISTINCT FROM
            round(v_row.new_base_cogs*product_uom.factor_to_base,4)
        RETURNING 1
      ) SELECT count(*) INTO v_uom_change_count
        FROM changed;
      v_changed_uom_count:=v_changed_uom_count+v_uom_change_count;

      SELECT jsonb_build_object('product',to_jsonb(product),'uoms',COALESCE((
        SELECT jsonb_agg(to_jsonb(product_uom)
          ORDER BY product_uom.factor_to_base,product_uom.id)
        FROM public.product_uoms product_uom
        WHERE product_uom.company_id=v_target.company_id
          AND product_uom.product_id=v_row.product_id),'[]'::JSONB))
      INTO v_after FROM public.products product
      WHERE product.company_id=v_target.company_id
        AND product.id=v_row.product_id;

      IF v_before IS DISTINCT FROM v_after THEN
        INSERT INTO public.product_master_audit(
          company_id,product_id,action,actor_id,before_snapshot,after_snapshot
        ) VALUES(v_target.company_id,v_row.product_id,'UPDATE',
          v_target.actor_id,v_before,v_after);
      END IF;
    END LOOP;

    SELECT count(*) INTO v_verified_uom_count
    FROM kgs_cogs_update_plan plan
    JOIN public.product_uoms product_uom
      ON product_uom.company_id=v_target.company_id
     AND product_uom.product_id=plan.product_id
     AND product_uom.is_active
    WHERE plan.row_status='VALID'
      AND product_uom.purchase_price=
        round(plan.new_base_cogs*product_uom.factor_to_base,4);

    IF EXISTS(
      SELECT 1 FROM kgs_cogs_update_plan plan
      JOIN public.products product
        ON product.company_id=v_target.company_id
       AND product.id=plan.product_id
      WHERE plan.row_status='VALID'
        AND product.cogs IS DISTINCT FROM plan.new_base_cogs
    ) OR EXISTS(
      SELECT 1 FROM kgs_cogs_update_plan plan
      JOIN public.product_uoms product_uom
        ON product_uom.company_id=v_target.company_id
       AND product_uom.product_id=plan.product_id
       AND product_uom.is_active
      WHERE plan.row_status='VALID'
        AND product_uom.purchase_price IS DISTINCT FROM
          round(plan.new_base_cogs*product_uom.factor_to_base,4)
    ) THEN
      RAISE EXCEPTION 'FINAL_COGS_VERIFICATION_FAILED';
    END IF;

    INSERT INTO kgs_cogs_update_result VALUES(
      'final_cogs_verification','PASS',jsonb_build_object(
        'changedProducts',v_changed_product_count,
        'changedActiveProductUoms',v_changed_uom_count,
        'verifiedActiveProductUoms',v_verified_uom_count,
        'companyCode',v_target.company_code));
END
$operation$;

COMMIT;

SELECT check_name,status,details
FROM kgs_cogs_update_result
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1
                     WHEN 'APPLY' THEN 2 WHEN 'PREVIEW' THEN 3 ELSE 4 END,
         check_name;

SELECT row_number,source_sku,source_product_name,product_name,row_status,
       issue_code,warning_code,pack_factor,cogs_per_pack,
       old_base_cogs,new_base_cogs
FROM kgs_cogs_update_plan
ORDER BY row_number;
