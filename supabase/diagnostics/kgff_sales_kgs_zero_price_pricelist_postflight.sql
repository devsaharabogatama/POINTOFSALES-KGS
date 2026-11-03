-- SELECT-only postflight. One result set; no mutation.
WITH company_target AS (
  SELECT id FROM public.companies WHERE id='a59c534b-909f-4b3f-aba0-ae9db6d90b76'::uuid
    AND company_code='KGFF' AND status='ACTIVE'
), customer_target AS (
  SELECT customer.* FROM public.customers customer JOIN company_target company
    ON company.id=customer.company_id
  WHERE customer.id='c24ac084-5692-4722-9413-3ed46c734af9'::uuid
    AND customer.code='KGS003' AND customer.name='SALES KGS'
), pricelist_target AS (
  SELECT pricelist.* FROM public.pricelists pricelist JOIN company_target company
    ON company.id=pricelist.company_id
  WHERE pricelist.code='SAMPLE-SALES-KGS' AND pricelist.name='Sample SALES KGS'
), catalog_target AS (
  SELECT product.id product_id,product_uom.id product_uom_id
  FROM company_target company
  JOIN public.products product ON product.company_id=company.id
  JOIN public.product_uoms product_uom ON product_uom.company_id=product.company_id
    AND product_uom.product_id=product.id
  JOIN public.uoms unit ON unit.company_id=product_uom.company_id
    AND unit.id=product_uom.uom_id
  WHERE product.is_active AND NOT product.is_bundle AND product_uom.is_active
    AND product_uom.sales_allowed AND unit.is_active
), rule_target AS (
  SELECT rule.* FROM public.pricelist_rules rule JOIN pricelist_target pricelist
    ON pricelist.company_id=rule.company_id AND pricelist.id=rule.pricelist_id
  WHERE rule.is_active
), checks AS (
  SELECT 1 ordinal,'kgff_sales_kgs_sample_pricelist_postflight_migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20261103100000'
  UNION ALL
  SELECT 2,'kgff_sales_kgs_sample_pricelist_postflight_header_assignment',
    CASE WHEN (SELECT count(*) FROM pricelist_target)=1
      AND (SELECT count(*) FROM customer_target WHERE is_active AND NOT is_system_customer
        AND default_pricelist_id=(SELECT id FROM pricelist_target))=1
      AND (SELECT count(*) FROM pricelist_target WHERE scope='CUSTOMER' AND customer_id IS NULL
        AND NOT is_default AND applies_all_stores AND is_active)=1
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN (SELECT count(*) FROM pricelist_target)=1
      AND (SELECT count(*) FROM customer_target WHERE is_active AND NOT is_system_customer
        AND default_pricelist_id=(SELECT id FROM pricelist_target))=1 THEN 0 ELSE 1 END,
    jsonb_build_object('pricelistRows',(SELECT count(*) FROM pricelist_target),
      'assignedCustomerRows',(SELECT count(*) FROM customer_target
        WHERE default_pricelist_id=(SELECT id FROM pricelist_target)))
  UNION ALL
  SELECT 3,'kgff_sales_kgs_sample_pricelist_postflight_rule_coverage',
    CASE WHEN (SELECT count(*) FROM catalog_target)=(SELECT count(*) FROM rule_target)
      AND NOT EXISTS(SELECT product_uom_id FROM catalog_target EXCEPT SELECT product_uom_id FROM rule_target)
      AND NOT EXISTS(SELECT product_uom_id FROM rule_target EXCEPT SELECT product_uom_id FROM catalog_target)
      AND NOT EXISTS(SELECT 1 FROM rule_target WHERE pricing_method<>'FIXED_PRICE'
        OR fixed_unit_price<>0 OR min_qty<>1 OR tier_qty_basis<>'SALES_UOM'
        OR discount_amount_per_unit IS NOT NULL OR discount_percent IS NOT NULL)
      THEN 'PASS' ELSE 'FAIL' END,
    abs((SELECT count(*) FROM catalog_target)-(SELECT count(*) FROM rule_target))::bigint,
    jsonb_build_object('activeSaleUoms',(SELECT count(*) FROM catalog_target),
      'activeZeroRules',(SELECT count(*) FROM rule_target))
  UNION ALL
  SELECT 4,'kgff_sales_kgs_sample_pricelist_postflight_audit_contract',
    CASE WHEN (SELECT count(*) FROM public.pricelist_master_audit audit
        JOIN pricelist_target pricelist ON pricelist.company_id=audit.company_id
          AND pricelist.id=audit.pricelist_id WHERE audit.action='CREATE')=1
      AND (SELECT count(*) FROM public.customer_master_audit audit
        JOIN customer_target customer ON customer.company_id=audit.company_id
          AND customer.id=audit.customer_id
        WHERE audit.action='UPDATE'
          AND audit.after_state->>'default_pricelist_id'=(SELECT id::text FROM pricelist_target))=1
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN (SELECT count(*) FROM public.pricelist_master_audit audit
        JOIN pricelist_target pricelist ON pricelist.company_id=audit.company_id
          AND pricelist.id=audit.pricelist_id WHERE audit.action='CREATE')=1
      AND (SELECT count(*) FROM public.customer_master_audit audit
        JOIN customer_target customer ON customer.company_id=audit.company_id
          AND customer.id=audit.customer_id
        WHERE audit.action='UPDATE'
          AND audit.after_state->>'default_pricelist_id'=(SELECT id::text FROM pricelist_target))=1
      THEN 0 ELSE 1 END,
    jsonb_build_object('pricelistCreateAudits',(SELECT count(*) FROM public.pricelist_master_audit audit
      JOIN pricelist_target pricelist ON pricelist.company_id=audit.company_id AND pricelist.id=audit.pricelist_id),
      'customerAssignmentAudits',(SELECT count(*) FROM public.customer_master_audit audit
      JOIN customer_target customer ON customer.company_id=audit.company_id AND customer.id=audit.customer_id
      WHERE audit.after_state->>'default_pricelist_id'=(SELECT id::text FROM pricelist_target)))
  UNION ALL
  SELECT 5,'kgff_sales_kgs_sample_pricelist_postflight_business_boundary','INFO',0,
    jsonb_build_object('databaseState','DATABASE LIVE only if all mandatory rows PASS',
      'changed',ARRAY['one KGFF Customer Pricelist','SALES KGS default Pricelist assignment'],
      'preserved',ARRAY['Product base prices','other Pricelists and Customers','existing Sales','Stock/FIFO/Payment/Finance'],
      'remainingSeparateGate','zero-total Sample checkout and Expense journal behavior')
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY ordinal;
