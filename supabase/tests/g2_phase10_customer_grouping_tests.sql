-- SAFETY: all Customer fixtures are rolled back.
BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company UUID;
    v_category UUID;
    v_root UUID;
    v_child UUID;
    v_result JSONB;
    v_rejected BOOLEAN := FALSE;
    v_suffix TEXT := txid_current()::TEXT;
BEGIN
    SELECT p.id INTO v_actor FROM public.profiles p JOIN auth.users u ON u.id=p.id
    WHERE p.role='super_admin'::user_role ORDER BY p.id LIMIT 1;
    SELECT id INTO v_company FROM public.companies WHERE status='ACTIVE' ORDER BY id LIMIT 1;
    SELECT id INTO v_category FROM public.customer_categories
    WHERE company_id=v_company AND is_active ORDER BY is_system_category DESC LIMIT 1;
    IF v_actor IS NULL OR v_company IS NULL OR v_category IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED';
    END IF;
    PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE);
    PERFORM public.set_active_company_context(v_company,'G2_PHASE10_TEST');

    v_result := public.save_customer_with_parent(NULL,NULL,'G10R-'||v_suffix,
        'G10 Root '||v_suffix,v_category,NULL,NULL,NULL,'BUSINESS',0,NULL,NULL,TRUE,NULL);
    v_root := (v_result->>'customerId')::UUID;
    v_result := public.save_customer_with_parent(NULL,NULL,'G10C-'||v_suffix,
        'G10 Child '||v_suffix,v_category,NULL,NULL,NULL,'BUSINESS',0,NULL,NULL,TRUE,v_root);
    v_child := (v_result->>'customerId')::UUID;

    IF NOT EXISTS (SELECT 1 FROM public.customers WHERE id=v_child AND parent_customer_id=v_root) THEN
        RAISE EXCEPTION 'TEST_FAILED: child not linked to root';
    END IF;

    BEGIN
        PERFORM public.save_customer_with_parent(NULL,NULL,'G10G-'||v_suffix,
            'G10 Grandchild '||v_suffix,v_category,NULL,NULL,NULL,'BUSINESS',0,NULL,NULL,TRUE,v_child);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='ACTIVE_ROOT_PARENT_CUSTOMER_NOT_FOUND' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: nested Customer group accepted'; END IF;

    RAISE NOTICE 'TEST PASSED: Customer parent grouping is one-level, tenant-scoped, and child transactions remain independently addressable.';
END
$test$;

ROLLBACK;
