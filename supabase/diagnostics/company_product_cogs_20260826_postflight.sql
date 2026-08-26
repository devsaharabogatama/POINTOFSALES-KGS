-- COGS-only update postflight for LSM, SMS and KMS.
-- SAFETY: SELECT-only. No temp table, write, lock, sequence or routine call.

WITH source(row_number,sku,cogs_per_pack) AS (VALUES
  (3,'T16B',14630::NUMERIC),(4,'T17B',14630),(5,'T19B',17330),
  (6,'T20B',17330),(7,'T22B',20983),(8,'T23B',20983),
  (9,'T24B',22948),(10,'T25B',22948),(11,'T26B',24811),
  (12,'T27B',24811),(13,'T16BC',14855),(14,'T17BC',14855),
  (15,'T19BC',17631),(16,'T20BC',17631),(17,'T22BC',21397),
  (18,'T23BC',21397),(19,'T24BC',23437),(20,'T25BC',23437),
  (21,'T26BC',25363),(22,'T27BC',25363),(23,'T16B10',14944),
  (24,'T17B10',14944),(25,'T19B10',17609),(26,'T20B10',17609),
  (27,'T22B10',21157),(28,'T23B10',21157),(29,'T24B10',23122),
  (30,'T25B10',23122),(31,'T26B10',24959),(32,'T27B10',24959),
  (33,'T16BB',16294),(34,'T17BB',16294),(35,'T19BB',19549),
  (36,'T20BB',19549),(37,'T22BB',24035),(38,'T23BB',24035),
  (39,'T24BB',26555),(40,'T25BB',26555),(41,'T26BB',28880),
  (42,'T27BB',28880),(43,'BRB6',7479),(44,'BRBD6',7350),
  (45,'BRBB6',7479),(46,'BRB10',13592),(47,'BRB10-2',13592)
), target_company AS (
  SELECT company.id,company.company_code,company.company_name
  FROM public.companies company
  WHERE company.status='ACTIVE'
    AND upper(btrim(company.company_code)) IN('LSM','SMS','KMS')
), matched AS (
  SELECT company.id AS company_id,company.company_code,source.row_number,
         source.sku,source.cogs_per_pack,product.id AS product_id,
         product.name AS product_name,product.cogs AS actual_base_cogs,
         pack.pack_count,pack.pack_factor,
         CASE WHEN pack.pack_factor>0
           THEN round(source.cogs_per_pack/pack.pack_factor,4) END
           AS expected_base_cogs
  FROM target_company company CROSS JOIN source
  LEFT JOIN public.products product
    ON product.company_id=company.id
   AND upper(regexp_replace(btrim(product.sku),'\s+',' ','g'))=
       upper(regexp_replace(btrim(source.sku),'\s+',' ','g'))
   AND product.is_active AND NOT product.is_bundle
  LEFT JOIN LATERAL (
    SELECT count(*)::INTEGER AS pack_count,
           min(product_uom.factor_to_base) AS pack_factor
    FROM public.product_uoms product_uom
    JOIN public.uoms uom
      ON uom.company_id=product_uom.company_id AND uom.id=product_uom.uom_id
    WHERE product_uom.company_id=product.company_id
      AND product_uom.product_id=product.id AND product_uom.is_active
      AND (upper(btrim(uom.code))='PACK' OR upper(btrim(uom.name))='PACK')
  ) pack ON product.id IS NOT NULL
), base_violation AS (
  SELECT * FROM matched
  WHERE product_id IS NOT NULL AND pack_count=1 AND pack_factor>0
    AND actual_base_cogs IS DISTINCT FROM expected_base_cogs
), uom_violation AS (
  SELECT matched.company_code,matched.sku,product_uom.id AS product_uom_id,
         product_uom.purchase_price AS actual_purchase_price,
         round(matched.expected_base_cogs*product_uom.factor_to_base,4)
           AS expected_purchase_price
  FROM matched
  JOIN public.product_uoms product_uom
    ON product_uom.company_id=matched.company_id
   AND product_uom.product_id=matched.product_id AND product_uom.is_active
  WHERE matched.pack_count=1 AND matched.pack_factor>0
    AND product_uom.purchase_price IS DISTINCT FROM
      round(matched.expected_base_cogs*product_uom.factor_to_base,4)
), checks AS (
  SELECT 'target_company_scope' check_name,
    CASE WHEN (SELECT count(*) FROM target_company)=3 THEN 'PASS' ELSE 'FAIL' END status,
    jsonb_build_object('expected',3,'companyCount',
      (SELECT count(*) FROM target_company),'companyCodes',COALESCE((
        SELECT jsonb_agg(company_code ORDER BY company_code)
        FROM target_company),'[]'::JSONB)) details
  UNION ALL
  SELECT 'matched_product_scope',
    CASE WHEN EXISTS(SELECT 1 FROM matched WHERE product_id IS NOT NULL)
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('sourceRowsPerCompany',45,'matchedByCompany',COALESCE((
      SELECT jsonb_object_agg(company_code,matched_count) FROM (
        SELECT company_code,count(*) FILTER(WHERE product_id IS NOT NULL)
          AS matched_count FROM matched GROUP BY company_code
      ) grouped),'{}'::JSONB),'skippedByCompany',COALESCE((
      SELECT jsonb_object_agg(company_code,skipped_count) FROM (
        SELECT company_code,count(*) FILTER(WHERE product_id IS NULL)
          AS skipped_count FROM matched GROUP BY company_code
      ) grouped),'{}'::JSONB))
  UNION ALL
  SELECT 'pack_conversion_contract',
    CASE WHEN NOT EXISTS(SELECT 1 FROM matched
      WHERE product_id IS NOT NULL AND (pack_count<>1 OR pack_factor<=0))
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('invalidRows',(SELECT count(*) FROM matched
      WHERE product_id IS NOT NULL AND (pack_count<>1 OR pack_factor<=0)))
  UNION ALL
  SELECT 'product_base_cogs_contract',
    CASE WHEN NOT EXISTS(SELECT 1 FROM base_violation) THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('violationRows',(SELECT count(*) FROM base_violation),
      'sample',COALESCE((SELECT jsonb_agg(to_jsonb(sample)) FROM (
        SELECT company_code,sku,actual_base_cogs,expected_base_cogs
        FROM base_violation ORDER BY company_code,sku LIMIT 20
      ) sample),'[]'::JSONB))
  UNION ALL
  SELECT 'active_product_uom_cogs_contract',
    CASE WHEN NOT EXISTS(SELECT 1 FROM uom_violation) THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('violationRows',(SELECT count(*) FROM uom_violation),
      'sample',COALESCE((SELECT jsonb_agg(to_jsonb(sample)) FROM (
        SELECT company_code,sku,actual_purchase_price,expected_purchase_price
        FROM uom_violation ORDER BY company_code,sku LIMIT 20
      ) sample),'[]'::JSONB))
  UNION ALL
  SELECT 'cogs_update_inventory','INFO',jsonb_build_object(
    'matchedRows',(SELECT count(*) FROM matched WHERE product_id IS NOT NULL),
    'skippedRows',(SELECT count(*) FROM matched WHERE product_id IS NULL),
    'verifiedActiveUoms',(SELECT count(*) FROM matched
      JOIN public.product_uoms product_uom
        ON product_uom.company_id=matched.company_id
       AND product_uom.product_id=matched.product_id
       AND product_uom.is_active
      WHERE matched.pack_count=1 AND matched.pack_factor>0))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,
         check_name;
