-- G4 phase 58 behavior: guarded negative-stock configuration only.
-- SAFETY: all fixtures/configuration are rolled back; no negative stock created.
BEGIN;

DO $test$
DECLARE
    v_actor UUID; v_company UUID:='00000000-0000-0000-0000-000000088001';
    v_other UUID:='00000000-0000-0000-0000-000000088002';
    v_store UUID:='00000000-0000-0000-0000-000000088011';
    v_warehouse UUID:='00000000-0000-0000-0000-000000088021';
    v_other_warehouse UUID:='00000000-0000-0000-0000-000000088022';
    v_result JSONB; v_permission UUID; v_count BIGINT; v_rejected BOOLEAN;
BEGIN
    SELECT profile.id INTO v_actor FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.role='super_admin'::public.user_role
    ORDER BY profile.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
    VALUES(v_company,'G88A','G88 Company A','g88-company-a','ACTIVE'),
          (v_other,'G88B','G88 Company B','g88-company-b','ACTIVE');
    INSERT INTO public.stores(id,company_id,store_code,store_name,status)
    VALUES(v_store,v_company,'G88S','G88 Store','ACTIVE');
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type,store_id,
        is_sale_source,is_purchase_destination,is_active
    ) VALUES(
        v_warehouse,v_company,'G88W','G88 Warehouse','STORE',v_store,
        TRUE,FALSE,TRUE
    );
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type,
        is_sale_source,is_purchase_destination,is_active
    ) VALUES(
        v_other_warehouse,v_other,'G88X','G88 Other Warehouse','CENTRAL',
        TRUE,FALSE,TRUE
    );

    PERFORM set_config('request.jwt.claims',jsonb_build_object(
        'sub',v_actor,'role','authenticated')::TEXT,TRUE);
    PERFORM public.set_active_company_context(v_company,'G4_PHASE58_TEST');

    IF NOT EXISTS(SELECT 1 FROM public.pos_negative_stock_policies
        WHERE company_id=v_company AND NOT is_active AND require_reason) THEN
        RAISE EXCEPTION 'TEST_FAILED: default policy not provisioned closed';
    END IF;
    PERFORM public.set_company_feature(
        v_company,'pos_negative_stock_enabled',TRUE,'{}'::JSONB
    );
    v_result:=public.save_pos_negative_stock_policy(1,TRUE,TRUE,100);
    IF (v_result->>'masterVersion')::BIGINT<>2
       OR NOT (v_result->>'isActive')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: policy update invalid';
    END IF;
    v_result:=public.set_warehouse_negative_stock_opt_in(v_warehouse,TRUE);
    IF NOT (v_result->>'allowNegativeStock')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: Warehouse opt-in invalid';
    END IF;
    v_result:=public.save_pos_negative_stock_permission(
        NULL,NULL,v_warehouse,v_actor,20,clock_timestamp()+interval '1 day',
        'Emergency authorized test',TRUE
    );
    v_permission:=(v_result->>'permissionId')::UUID;
    IF v_permission IS NULL OR (v_result->>'masterVersion')::BIGINT<>1 THEN
        RAISE EXCEPTION 'TEST_FAILED: actor permission create invalid';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.pos_negative_stock_configuration_audit
    WHERE company_id=v_company AND actor_id=v_actor;
    IF v_count<>3 THEN
        RAISE EXCEPTION 'TEST_FAILED: expected three audit rows, got %',v_count;
    END IF;

    v_rejected:=FALSE;
    BEGIN
        PERFORM public.save_pos_negative_stock_policy(1,FALSE,TRUE,NULL);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='MASTER_VERSION_CONFLICT' THEN v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: stale policy update accepted';
    END IF;

    v_rejected:=FALSE;
    BEGIN
        PERFORM public.set_warehouse_negative_stock_opt_in(
            v_other_warehouse,TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='ACTIVE_SALE_SOURCE_WAREHOUSE_REQUIRED' THEN
            v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company Warehouse accepted';
    END IF;

    IF EXISTS(SELECT 1 FROM public.product_stocks WHERE stock_qty<0)
       OR EXISTS(SELECT 1 FROM public.product_batches
                 WHERE qty_purchased<0 OR qty_remaining<0) THEN
        RAISE EXCEPTION 'TEST_FAILED: configuration created negative inventory';
    END IF;
    IF has_table_privilege('authenticated',
           'public.pos_negative_stock_permissions','INSERT,UPDATE,DELETE')
       OR has_table_privilege('authenticated','public.warehouses','UPDATE')
       OR NOT has_function_privilege('authenticated',
           'public.save_pos_negative_stock_permission(uuid,bigint,uuid,uuid,numeric,timestamptz,text,boolean)',
           'EXECUTE') THEN
        RAISE EXCEPTION 'TEST_FAILED: browser boundary invalid';
    END IF;
    RAISE NOTICE 'TEST PASSED: negative-stock configuration is default-OFF, tenant-safe, guarded, versioned, and audited; Sale runtime remains closed.';
END
$test$;

ROLLBACK;
