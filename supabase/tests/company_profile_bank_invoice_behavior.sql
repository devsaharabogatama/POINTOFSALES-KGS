-- Rollback-safe behavioral check. Requires one active Owner/Admin membership.
BEGIN;
DO $test$
DECLARE v_actor UUID;v_company UUID;v_profile JSONB;v_branding JSONB;
  v_initial_version BIGINT;v_saved_version BIGINT;
BEGIN
  SELECT membership.user_id,membership.company_id INTO v_actor,v_company
  FROM public.company_memberships membership
  JOIN public.companies company ON company.id=membership.company_id AND company.status='ACTIVE'
  WHERE membership.status='ACTIVE' AND membership.role_code IN('COMPANY_OWNER','COMPANY_ADMIN')
  ORDER BY membership.role_code='COMPANY_OWNER' DESC,membership.created_at LIMIT 1;
  IF v_actor IS NULL THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Company Owner/Admin required'; END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE') ON CONFLICT(user_id) DO UPDATE SET
    company_id=EXCLUDED.company_id,selection_source=EXCLUDED.selection_source;

  v_profile:=public.get_company_profile();
  v_initial_version:=(v_profile->>'profileMasterVersion')::BIGINT;
  v_profile:=public.save_company_profile(
    v_initial_version,'PT Behavioral Test','00.000.000.0-000.000',
    'NIB-TEST','Alamat Test','Jakarta','DKI Jakarta','12345','Indonesia',
    '021000000','test@example.invalid','https://example.invalid',
    'Bank Test','0012345678','PT Behavioral Test');
  IF v_profile->>'bankAccountNumber'<>'0012345678' THEN
    RAISE EXCEPTION 'TEST_FAILED: Company bank account was not saved as text';
  END IF;
  v_saved_version:=(v_profile->>'profileMasterVersion')::BIGINT;
  v_profile:=public.save_company_profile(
    v_initial_version,'PT Behavioral Test','00.000.000.0-000.000',
    'NIB-TEST','Alamat Test','Jakarta','DKI Jakarta','12345','Indonesia',
    '021000000','test@example.invalid','https://example.invalid',
    'Bank Test','0012345678','PT Behavioral Test');
  IF (v_profile->>'profileMasterVersion')::BIGINT<>v_saved_version THEN
    RAISE EXCEPTION 'TEST_FAILED: exact profile retry changed version';
  END IF;
  BEGIN
    PERFORM public.save_company_profile(
      (v_profile->>'profileMasterVersion')::BIGINT,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
      'Bank Incomplete',NULL,NULL);
    RAISE EXCEPTION 'TEST_FAILED: incomplete bank identity accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%COMPANY_BANK_ACCOUNT_INCOMPLETE%' THEN RAISE; END IF;
  END;

  v_branding:=public.get_company_branding();
  v_branding:=public.save_company_document_visibility(
    CASE WHEN v_branding->>'masterVersion' IS NULL THEN NULL
      ELSE (v_branding->>'masterVersion')::BIGINT END,
    COALESCE((v_branding->>'showLogoOnDocuments')::BOOLEAN,TRUE),
    COALESCE((v_branding->>'showStampOnDocuments')::BOOLEAN,FALSE),TRUE);
  IF COALESCE((v_branding->>'showBankAccountOnInvoice')::BOOLEAN,FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: Invoice bank visibility not enabled';
  END IF;
END
$test$;
ROLLBACK;
