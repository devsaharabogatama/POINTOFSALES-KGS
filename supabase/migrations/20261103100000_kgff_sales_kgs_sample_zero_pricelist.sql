-- KGFF SALES KGS zero-price Customer Pricelist configuration.
-- Configuration only: zero-total Sample checkout remains a separate gate.

BEGIN;

DO $migration$
DECLARE
  v_version constant text := '20261103100000';
  v_company constant uuid := 'a59c534b-909f-4b3f-aba0-ae9db6d90b76'::uuid;
  v_customer constant uuid := 'c24ac084-5692-4722-9413-3ed46c734af9'::uuid;
  v_pricelist uuid := gen_random_uuid();
  v_actor uuid;
  v_before jsonb;
  v_after jsonb;
  v_expected bigint;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260722070000','20260722100000','20260729070000',
        '20260729100000','20261008130000'))<>5 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: exact dependency chain required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version=v_version) THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: %',v_version;
  END IF;
  IF (SELECT count(*) FROM public.companies company
      WHERE company.id=v_company AND company.company_code='KGFF'
        AND company.company_name='Kidul Gunung Frozen Food'
        AND company.status='ACTIVE')<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: exact KGFF Company required';
  END IF;
  IF (SELECT count(*) FROM public.customers customer
      WHERE customer.id=v_customer AND customer.company_id=v_company
        AND customer.code='KGS003' AND customer.name='SALES KGS'
        AND customer.is_active AND NOT customer.is_system_customer
        AND customer.default_pricelist_id IS NULL)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: exact unassigned SALES KGS Customer required';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pricelists pricelist
      WHERE pricelist.company_id=v_company AND (
        upper(regexp_replace(btrim(pricelist.code),'\s+',' ','g'))='SAMPLE-SALES-KGS'
        OR lower(regexp_replace(btrim(pricelist.name),'\s+',' ','g'))=
          lower('Sample SALES KGS'))) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: target Pricelist identity already exists';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs queue
      WHERE queue.company_id=v_company
        AND queue.status IN('PREVIEWED','APPROVED','PROCESSING'))
     OR EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions submission
      WHERE submission.company_id=v_company
        AND submission.status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active runtime queue';
  END IF;
  SELECT count(*) INTO v_expected
  FROM public.products product
  JOIN public.product_uoms product_uom
    ON product_uom.company_id=product.company_id
   AND product_uom.product_id=product.id
  JOIN public.uoms unit ON unit.company_id=product_uom.company_id
   AND unit.id=product_uom.uom_id
  WHERE product.company_id=v_company AND product.is_active
    AND NOT product.is_bundle AND product_uom.is_active
    AND product_uom.sales_allowed AND unit.is_active;
  IF v_expected<=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active sale Product-UOM required';
  END IF;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  WHERE public.private_is_super_admin(profile.id) ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: linked Super Admin required';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('KGFF_SAMPLE_PRICELIST|'||v_company::text,0));
  PERFORM 1 FROM public.customers customer
  WHERE customer.company_id=v_company AND customer.id=v_customer FOR UPDATE;

  INSERT INTO public.pricelists(
    id,company_id,code,name,scope,customer_id,priority,is_default,
    applies_all_stores,is_active,notes,created_by,updated_by
  ) VALUES (
    v_pricelist,v_company,'SAMPLE-SALES-KGS','Sample SALES KGS','CUSTOMER',
    NULL,100,FALSE,TRUE,TRUE,
    'Harga Rp0 khusus sample SALES KGS; checkout sample memerlukan gate runtime terpisah.',
    v_actor,v_actor
  );

  INSERT INTO public.pricelist_rules(
    company_id,pricelist_id,product_id,product_uom_id,min_qty,
    tier_qty_basis,pricing_method,fixed_unit_price,is_active,rule_version,
    created_by,updated_by
  )
  SELECT v_company,v_pricelist,product.id,product_uom.id,1,
    'SALES_UOM','FIXED_PRICE',0,TRUE,1,v_actor,v_actor
  FROM public.products product
  JOIN public.product_uoms product_uom
    ON product_uom.company_id=product.company_id
   AND product_uom.product_id=product.id
  JOIN public.uoms unit ON unit.company_id=product_uom.company_id
   AND unit.id=product_uom.uom_id
  WHERE product.company_id=v_company AND product.is_active
    AND NOT product.is_bundle AND product_uom.is_active
    AND product_uom.sales_allowed AND unit.is_active;

  SELECT to_jsonb(pricelist) INTO v_after FROM public.pricelists pricelist
  WHERE pricelist.company_id=v_company AND pricelist.id=v_pricelist;
  INSERT INTO public.pricelist_master_audit(
    company_id,pricelist_id,action,actor_id,before_state,after_state
  ) VALUES(v_company,v_pricelist,'CREATE',v_actor,NULL,v_after);

  SELECT to_jsonb(customer) INTO v_before FROM public.customers customer
  WHERE customer.company_id=v_company AND customer.id=v_customer;
  UPDATE public.customers SET default_pricelist_id=v_pricelist,updated_by=v_actor
  WHERE company_id=v_company AND id=v_customer;
  SELECT to_jsonb(customer) INTO v_after FROM public.customers customer
  WHERE customer.company_id=v_company AND customer.id=v_customer;
  INSERT INTO public.customer_master_audit(
    company_id,customer_id,action,actor_id,before_state,after_state
  ) VALUES(v_company,v_customer,'UPDATE',v_actor,v_before,v_after);

  IF (SELECT count(*) FROM public.pricelist_rules rule
      WHERE rule.company_id=v_company AND rule.pricelist_id=v_pricelist
        AND rule.is_active AND rule.min_qty=1
        AND rule.tier_qty_basis='SALES_UOM'
        AND rule.pricing_method='FIXED_PRICE' AND rule.fixed_unit_price=0
        AND rule.discount_amount_per_unit IS NULL
        AND rule.discount_percent IS NULL)<>v_expected
     OR EXISTS(
       SELECT product_uom.id
       FROM public.products product
       JOIN public.product_uoms product_uom
         ON product_uom.company_id=product.company_id
        AND product_uom.product_id=product.id
       JOIN public.uoms unit ON unit.company_id=product_uom.company_id
        AND unit.id=product_uom.uom_id
       WHERE product.company_id=v_company AND product.is_active
         AND NOT product.is_bundle AND product_uom.is_active
         AND product_uom.sales_allowed AND unit.is_active
       EXCEPT
       SELECT rule.product_uom_id FROM public.pricelist_rules rule
       WHERE rule.company_id=v_company AND rule.pricelist_id=v_pricelist
         AND rule.is_active)
     OR EXISTS(
       SELECT rule.product_uom_id FROM public.pricelist_rules rule
       WHERE rule.company_id=v_company AND rule.pricelist_id=v_pricelist
         AND rule.is_active
       EXCEPT
       SELECT product_uom.id
       FROM public.products product
       JOIN public.product_uoms product_uom
         ON product_uom.company_id=product.company_id
        AND product_uom.product_id=product.id
       JOIN public.uoms unit ON unit.company_id=product_uom.company_id
        AND unit.id=product_uom.uom_id
       WHERE product.company_id=v_company AND product.is_active
         AND NOT product.is_bundle AND product_uom.is_active
         AND product_uom.sales_allowed AND unit.is_active) THEN
    RAISE EXCEPTION 'MIGRATION_POSTCONDITION_FAILED: exact zero-rule coverage';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.customers customer
      WHERE customer.company_id=v_company AND customer.id=v_customer
        AND customer.default_pricelist_id=v_pricelist) THEN
    RAISE EXCEPTION 'MIGRATION_POSTCONDITION_FAILED: SALES KGS assignment';
  END IF;

  INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
  VALUES(v_version,'kgff_sales_kgs_sample_zero_pricelist',
    'KGFF-only Customer Pricelist assigned to KGS003 SALES KGS; all active sale Product-UOM fixed to zero; no checkout behavior change');
END
$migration$;

COMMIT;
