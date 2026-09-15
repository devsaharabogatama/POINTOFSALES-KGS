-- Clone only, while holder owns the Company mode/cutover locks.
BEGIN;
SET LOCAL lock_timeout='500ms';
DO $test$
DECLARE v_company uuid;v_actor uuid;
BEGIN
 SELECT id INTO STRICT v_company FROM public.companies WHERE status='ACTIVE' ORDER BY id LIMIT 1;
 SELECT profile.id INTO STRICT v_actor FROM public.profiles profile JOIN auth.users user_row ON user_row.id=profile.id
 WHERE profile.role::text='super_admin' ORDER BY profile.id LIMIT 1;
 PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
 INSERT INTO public.user_active_company_contexts(user_id,company_id) VALUES(v_actor,v_company)
 ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id;
 BEGIN
  PERFORM public.recover_retained_sales_process_order(gen_random_uuid(),1,1,1,gen_random_uuid());
  RAISE EXCEPTION 'TEST_FAILED: recovery was not serialized behind Company lock';
 EXCEPTION WHEN lock_not_available THEN NULL; END;
END $test$;
ROLLBACK;
