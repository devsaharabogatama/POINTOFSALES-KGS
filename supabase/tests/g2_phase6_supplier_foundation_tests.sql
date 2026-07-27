-- G2 phase 6 behavioral test: Supplier and Product-Supplier guarded writes.
-- SAFETY: every fixture and audit row is rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_supplier_a UUID;
    v_supplier_a2 UUID;
    v_supplier_b UUID := '00000000-0000-0000-0000-000000013099';
    v_relation UUID;
    v_result JSONB;
    v_count BIGINT;
    v_rejected BOOLEAN;
BEGIN
    SELECT p.id INTO v_actor
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
    WHERE p.role = 'super_admin'::user_role
    ORDER BY p.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES
        ('00000000-0000-0000-0000-000000013001',
         'G13A','G13 Company A','g13-company-a','ACTIVE'),
        ('00000000-0000-0000-0000-000000013002',
         'G13B','G13 Company B','g13-company-b','ACTIVE');

    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES (
        '00000000-0000-0000-0000-000000013011',
        '00000000-0000-0000-0000-000000013001','TEST','Test'
    );
    INSERT INTO public.uoms(id,company_id,code,name) VALUES
        ('00000000-0000-0000-0000-000000013021',
         '00000000-0000-0000-0000-000000013001','KTL','Ketul'),
        ('00000000-0000-0000-0000-000000013022',
         '00000000-0000-0000-0000-000000013001','DUS','Dus');
    INSERT INTO public.products(
        id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
        weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
    ) VALUES (
        '00000000-0000-0000-0000-000000013031',
        '00000000-0000-0000-0000-000000013001','G13-P','G13 Product',
        'Test','00000000-0000-0000-0000-000000013011',100,50,'KTL',
        '00000000-0000-0000-0000-000000013021',
        '00000000-0000-0000-0000-000000013022',21,TRUE,FALSE
    );
    INSERT INTO public.product_uoms(
        company_id,product_id,uom_id,factor_to_base,purchase_allowed,
        sales_allowed,purchase_price,sale_price
    ) VALUES
        ('00000000-0000-0000-0000-000000013001',
         '00000000-0000-0000-0000-000000013031',
         '00000000-0000-0000-0000-000000013021',1,FALSE,TRUE,50,100),
        ('00000000-0000-0000-0000-000000013001',
         '00000000-0000-0000-0000-000000013031',
         '00000000-0000-0000-0000-000000013022',10,TRUE,FALSE,500,1000);

    INSERT INTO public.suppliers(
        id,company_id,supplier_code,supplier_name,created_by,updated_by
    ) VALUES (
        v_supplier_b,'00000000-0000-0000-0000-000000013002',
        'SUP-B','Supplier B',v_actor,v_actor
    );

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000013001','G2_PHASE6_TEST'
    );

    v_result := public.save_supplier(
        NULL,NULL,'SUP-A','Supplier A','Contact','0800','Address','NPWP',
        'NET 30','Bank A','123456','Supplier A',TRUE
    );
    v_supplier_a := (v_result->>'supplierId')::UUID;
    v_result := public.save_supplier(
        NULL,NULL,'SUP-A2','Supplier A2',NULL,NULL,NULL,NULL,NULL,
        NULL,NULL,NULL,TRUE
    );
    v_supplier_a2 := (v_result->>'supplierId')::UUID;

    SELECT count(*) INTO v_count FROM public.supplier_master_audit
    WHERE supplier_id IN (v_supplier_a,v_supplier_a2) AND action = 'CREATE';
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: Supplier create audit missing';
    END IF;

    v_result := public.save_supplier(
        v_supplier_a,1,'SUP-A','Supplier A Updated','Contact','0800',
        'Address','NPWP','NET 30','Bank A','654321','Supplier A',TRUE
    );
    IF (v_result->>'masterVersion')::BIGINT <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: Supplier version did not increment';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_supplier(
            v_supplier_a,1,'SUP-A','Stale Supplier',NULL,NULL,NULL,NULL,NULL,
            NULL,NULL,NULL,TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'MASTER_VERSION_CONFLICT' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: stale Supplier update accepted';
    END IF;

    v_result := public.save_product_supplier(
        NULL,NULL,'00000000-0000-0000-0000-000000013031',v_supplier_a,
        '00000000-0000-0000-0000-000000013022','VENDOR-KEBAB',500,
        TRUE,TRUE
    );
    v_relation := (v_result->>'productSupplierId')::UUID;
    SELECT count(*) INTO v_count FROM public.product_supplier_audit
    WHERE product_supplier_id = v_relation AND action = 'CREATE';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Product-Supplier audit missing';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_product_supplier(
            NULL,NULL,'00000000-0000-0000-0000-000000013031',
            v_supplier_b,'00000000-0000-0000-0000-000000013022',
            NULL,500,FALSE,TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_SUPPLIER_NOT_FOUND' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company Supplier accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_product_supplier(
            NULL,NULL,'00000000-0000-0000-0000-000000013031',
            v_supplier_a2,'00000000-0000-0000-0000-000000013022',
            NULL,510,TRUE,TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'PREFERRED_SUPPLIER_ALREADY_EXISTS' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: second preferred Supplier accepted';
    END IF;

    IF has_table_privilege('authenticated','public.suppliers','INSERT,UPDATE,DELETE')
       OR has_table_privilege(
            'authenticated','public.product_suppliers','INSERT,UPDATE,DELETE'
       )
       OR NOT has_function_privilege(
            'authenticated',
            'public.save_supplier(uuid,bigint,text,text,text,text,text,text,text,text,text,text,boolean)',
            'EXECUTE'
       ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Supplier privilege boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: Supplier and Product-Supplier writes are tenant-safe, versioned, preferred-unique, and audited.';
END
$test$;

ROLLBACK;
