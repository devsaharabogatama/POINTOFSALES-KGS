-- Ubah email login dan/atau nama akun yang sudah terdaftar.
-- SAFETY:
-- - default execute_change=FALSE (preview via NOTICE, tanpa write);
-- - target harus tepat satu user;
-- - password, role, Company, Store, permission, dan histori tidak berubah;
-- - perubahan email melalui SQL ini langsung dianggap confirmed dan tidak
--   mengirim email konfirmasi. User perlu login ulang memakai email baru.

BEGIN;

DO $operation$
DECLARE
  -- Cukup salin email akun dari hasil find_registered_user.sql.
  -- target_user_id hanya opsi cadangan dan boleh tetap NULL.
  target_user_id UUID := NULL;
  current_email TEXT := 'EMAIL_LAMA@CONTOH.COM';

  new_email TEXT := 'EMAIL_BARU@CONTOH.COM';
  new_name TEXT := 'NAMA AKUN BARU';

  execute_change BOOLEAN := FALSE;
  confirmation TEXT := ''; -- isi: UPDATE_REGISTERED_USER

  resolved_user_id UUID;
  matched_count BIGINT;
  old_email TEXT;
  old_name TEXT;
  normalized_email TEXT:=lower(btrim(COALESCE(new_email,'')));
  normalized_name TEXT:=btrim(COALESCE(new_name,''));
  email_identity_count BIGINT;
BEGIN
  IF target_user_id IS NULL AND (
    current_email IS NULL OR btrim(current_email)='' OR
    upper(btrim(current_email))='EMAIL_LAMA@CONTOH.COM') THEN
    RAISE EXCEPTION 'CONFIG_REQUIRED: target_user_id or exact current_email';
  END IF;

  SELECT count(*),(min(auth_user.id::TEXT))::UUID
  INTO matched_count,resolved_user_id
  FROM auth.users auth_user
  LEFT JOIN public.profiles profile ON profile.id=auth_user.id
  WHERE (target_user_id IS NOT NULL AND auth_user.id=target_user_id)
    OR (target_user_id IS NULL AND (
      lower(COALESCE(auth_user.email,''))=lower(btrim(current_email))
      OR lower(COALESCE(profile.email,''))=lower(btrim(current_email))
    ));

  IF matched_count=0 THEN RAISE EXCEPTION 'REGISTERED_USER_NOT_FOUND'; END IF;
  IF matched_count<>1 THEN RAISE EXCEPTION 'AMBIGUOUS_REGISTERED_USER: % rows',matched_count; END IF;

  SELECT auth_user.email,profile.name INTO old_email,old_name
  FROM auth.users auth_user LEFT JOIN public.profiles profile ON profile.id=auth_user.id
  WHERE auth_user.id=resolved_user_id FOR UPDATE OF auth_user;

  IF normalized_email='' OR normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    OR char_length(normalized_email)>320 THEN
    RAISE EXCEPTION 'INVALID_NEW_EMAIL';
  END IF;
  IF normalized_name='' OR char_length(normalized_name)>200 THEN
    RAISE EXCEPTION 'INVALID_NEW_NAME';
  END IF;

  IF EXISTS(SELECT 1 FROM auth.users auth_user
    WHERE auth_user.id<>resolved_user_id
      AND lower(COALESCE(auth_user.email,''))=normalized_email) THEN
    RAISE EXCEPTION 'NEW_EMAIL_ALREADY_USED_BY_AUTH_USER';
  END IF;
  IF EXISTS(SELECT 1 FROM public.profiles profile
    WHERE profile.id<>resolved_user_id
      AND lower(COALESCE(profile.email,''))=normalized_email) THEN
    RAISE EXCEPTION 'NEW_EMAIL_ALREADY_USED_BY_PROFILE';
  END IF;

  SELECT count(*) INTO email_identity_count FROM auth.identities identity
  WHERE identity.user_id=resolved_user_id AND identity.provider='email';

  RAISE NOTICE 'PREVIEW user_id=%, old_email=%, new_email=%, old_name=%, new_name=%, email_identities=%',
    resolved_user_id,old_email,normalized_email,old_name,normalized_name,email_identity_count;

  IF NOT execute_change THEN
    RAISE NOTICE 'PREVIEW_ONLY: set execute_change=TRUE and confirmation=UPDATE_REGISTERED_USER to apply';
    RETURN;
  END IF;
  IF confirmation<>'UPDATE_REGISTERED_USER' THEN
    RAISE EXCEPTION 'CONFIRMATION_REQUIRED: UPDATE_REGISTERED_USER';
  END IF;

  UPDATE auth.users SET
    email=normalized_email,
    raw_user_meta_data=COALESCE(raw_user_meta_data,'{}'::JSONB)
      || jsonb_build_object('name',normalized_name),
    email_change='',email_change_token_new='',email_change_token_current='',
    email_change_confirm_status=0,email_change_sent_at=NULL,
    updated_at=clock_timestamp()
  WHERE id=resolved_user_id;

  UPDATE public.profiles SET email=normalized_email,name=normalized_name
  WHERE id=resolved_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PROFILE_NOT_FOUND'; END IF;

  UPDATE auth.identities SET
    identity_data=COALESCE(identity_data,'{}'::JSONB)
      || jsonb_build_object('email',normalized_email),
    updated_at=clock_timestamp()
  WHERE user_id=resolved_user_id AND provider='email';

  IF NOT EXISTS(SELECT 1 FROM auth.users auth_user
      WHERE auth_user.id=resolved_user_id AND auth_user.email=normalized_email)
    OR NOT EXISTS(SELECT 1 FROM public.profiles profile
      WHERE profile.id=resolved_user_id AND profile.email=normalized_email
        AND profile.name=normalized_name)
    OR EXISTS(SELECT 1 FROM auth.identities identity
      WHERE identity.user_id=resolved_user_id AND identity.provider='email'
        AND COALESCE(identity.identity_data->>'email','')<>normalized_email) THEN
    RAISE EXCEPTION 'FINAL_IDENTITY_VERIFICATION_FAILED';
  END IF;

  RAISE NOTICE 'APPLIED user_id=%, login_email=%, account_name=%',
    resolved_user_id,normalized_email,normalized_name;
END
$operation$;

COMMIT;

-- Setelah APPLY, jalankan find_registered_user.sql memakai UUID atau email baru.
