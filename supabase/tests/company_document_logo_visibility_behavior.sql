BEGIN;
DO $setup$
DECLARE v_actor UUID;v_company UUID;
BEGIN
  SELECT membership.user_id,membership.company_id INTO v_actor,v_company
  FROM public.company_memberships membership
  JOIN public.companies company ON company.id=membership.company_id
  WHERE membership.status='ACTIVE' AND company.status='ACTIVE'
    AND membership.role_code IN('COMPANY_OWNER','COMPANY_ADMIN')
  ORDER BY CASE membership.role_code WHEN 'COMPANY_OWNER' THEN 0 ELSE 1 END,
    membership.company_id,membership.user_id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Company Owner/Admin required';
  END IF;
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE') ON CONFLICT(user_id) DO UPDATE SET
    company_id=EXCLUDED.company_id,selection_source=EXCLUDED.selection_source;
  PERFORM set_config('logo_test.actor',v_actor::TEXT,TRUE);
END
$setup$;
SELECT set_config('request.jwt.claims',jsonb_build_object(
  'sub',current_setting('logo_test.actor'),'role','authenticated')::TEXT,TRUE);
SET LOCAL ROLE authenticated;
DO $test$
DECLARE v_before JSONB;v_after JSONB;v_retry JSONB;
BEGIN
  v_before:=public.get_company_branding();
  v_after:=public.save_company_document_logo_visibility(
    NULLIF(v_before->>'masterVersion','')::BIGINT,
    NOT COALESCE((v_before->>'showLogoOnDocuments')::BOOLEAN,TRUE),
    NOT COALESCE((v_before->>'showStampOnDocuments')::BOOLEAN,FALSE));
  IF (v_after->>'showLogoOnDocuments')::BOOLEAN=
      COALESCE((v_before->>'showLogoOnDocuments')::BOOLEAN,TRUE) THEN
    RAISE EXCEPTION 'TEST_FAILED: document logo visibility did not change';
  END IF;
  IF (v_after->>'showStampOnDocuments')::BOOLEAN=
      COALESCE((v_before->>'showStampOnDocuments')::BOOLEAN,FALSE) THEN
    RAISE EXCEPTION 'TEST_FAILED: document stamp visibility did not change';
  END IF;
  v_retry:=public.save_company_document_logo_visibility(
    (v_after->>'masterVersion')::BIGINT,
    (v_after->>'showLogoOnDocuments')::BOOLEAN,
    (v_after->>'showStampOnDocuments')::BOOLEAN);
  IF v_retry->>'masterVersion'<>v_after->>'masterVersion' THEN
    RAISE EXCEPTION 'TEST_FAILED: exact retry changed master version';
  END IF;
END
$test$;
ROLLBACK;
