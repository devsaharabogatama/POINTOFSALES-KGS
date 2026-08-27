-- Rollback-safe behavioral test for Company Invoice date policy.
BEGIN;
DO $test$
DECLARE v_actor UUID;v_company UUID;v_branding JSONB;v_version BIGINT;
BEGIN
  SELECT membership.user_id,membership.company_id INTO v_actor,v_company
  FROM public.company_memberships membership
  JOIN public.companies company ON company.id=membership.company_id AND company.status='ACTIVE'
  WHERE membership.status='ACTIVE'
    AND membership.role_code IN('COMPANY_OWNER','COMPANY_ADMIN')
  ORDER BY membership.role_code='COMPANY_OWNER' DESC,membership.created_at LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Company Owner/Admin required';
  END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(v_company,'BACKOFFICE');

  v_branding:=public.get_company_branding();
  v_version:=CASE WHEN v_branding->>'masterVersion' IS NULL THEN NULL
    ELSE (v_branding->>'masterVersion')::BIGINT END;
  v_branding:=public.save_company_document_visibility(
    v_version,COALESCE((v_branding->>'showLogoOnDocuments')::BOOLEAN,TRUE),
    COALESCE((v_branding->>'showStampOnDocuments')::BOOLEAN,FALSE),
    COALESCE((v_branding->>'showBankAccountOnInvoice')::BOOLEAN,FALSE),
    'POSTED_DATE');
  IF v_branding->>'invoiceDateDisplayMode'<>'POSTED_DATE' THEN
    RAISE EXCEPTION 'TEST_FAILED: posted date policy not saved';
  END IF;

  v_version:=(v_branding->>'masterVersion')::BIGINT;
  v_branding:=public.save_company_document_visibility(
    v_version,COALESCE((v_branding->>'showLogoOnDocuments')::BOOLEAN,TRUE),
    COALESCE((v_branding->>'showStampOnDocuments')::BOOLEAN,FALSE),
    COALESCE((v_branding->>'showBankAccountOnInvoice')::BOOLEAN,FALSE),
    'POSTED_DATE');
  IF (v_branding->>'masterVersion')::BIGINT<>v_version THEN
    RAISE EXCEPTION 'TEST_FAILED: exact retry changed master version';
  END IF;

  BEGIN
    PERFORM public.save_company_document_visibility(
      v_version,TRUE,FALSE,FALSE,'INVALID');
    RAISE EXCEPTION 'TEST_FAILED: invalid Invoice date mode accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%INVOICE_DATE_DISPLAY_MODE_INVALID%' THEN RAISE; END IF;
  END;
END
$test$;
ROLLBACK;
