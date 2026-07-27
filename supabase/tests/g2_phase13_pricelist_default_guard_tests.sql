-- G2 phase 13 behavioral test: active Company cannot lose its default Global.
-- SAFETY: fixture and attempted mutations are rolled back.

BEGIN;

DO $test$
DECLARE
    v_company CONSTANT UUID := '00000000-0000-0000-0000-000000017001';
    v_actor UUID;
    v_default UUID;
    v_old_default UUID;
    v_result JSONB;
    v_count BIGINT;
    v_rejected BOOLEAN := FALSE;
BEGIN
    SELECT p.id INTO v_actor
    FROM public.profiles p
    JOIN auth.users u ON u.id=p.id
    WHERE p.role='super_admin'::user_role
    ORDER BY p.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES (
        v_company,'G17A','G17 Company A','g17-company-a','ACTIVE'
    );

    SELECT id INTO v_default FROM public.pricelists
    WHERE company_id=v_company AND scope='GLOBAL'
      AND is_default AND is_active;
    IF v_default IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: default Global was not provisioned';
    END IF;
    v_old_default:=v_default;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company,'G2_PHASE13_TEST');
    v_result:=public.save_pricelist_with_rules(
        NULL,NULL,'G17-NEW','G17 Default New','GLOBAL',NULL,10,TRUE,
        TRUE,NULL,NULL,NULL,TRUE,NULL,'[]'::JSONB
    );
    v_default:=(v_result->>'pricelistId')::UUID;

    SELECT count(*) INTO v_count FROM public.pricelists
    WHERE company_id=v_company AND scope='GLOBAL'
      AND is_default AND is_active;
    IF v_count<>1 OR NOT EXISTS(
        SELECT 1 FROM public.pricelists
        WHERE id=v_default AND is_default AND is_active
    ) OR EXISTS(
        SELECT 1 FROM public.pricelists
        WHERE id=v_old_default AND is_default
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: atomic default handover invalid';
    END IF;
    SELECT count(*) INTO v_count FROM public.pricelist_master_audit
    WHERE company_id=v_company
      AND pricelist_id IN (v_old_default,v_default);
    IF v_count<>2 THEN
        RAISE EXCEPTION 'TEST_FAILED: default handover audit incomplete';
    END IF;

    BEGIN
        UPDATE public.pricelists SET is_default=FALSE WHERE id=v_default;
        SET CONSTRAINTS g2_require_default_global_pricelist IMMEDIATE;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='ACTIVE_COMPANY_REQUIRES_ONE_DEFAULT_GLOBAL_PRICELIST' THEN
            v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: last default Global was removable';
    END IF;
    IF NOT EXISTS(
        SELECT 1 FROM public.pricelists WHERE id=v_default
          AND is_default AND is_active
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: rejected mutation partially persisted';
    END IF;

    RAISE NOTICE 'TEST PASSED: every active Company retains exactly one active default Global Pricelist.';
END
$test$;

ROLLBACK;
