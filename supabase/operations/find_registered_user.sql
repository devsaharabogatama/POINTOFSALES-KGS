-- Daftar seluruh akun terdaftar tanpa mengubah data.
-- Langsung jalankan untuk melihat semua akun.
-- search_text boleh dikosongkan; isi hanya bila ingin memfilter nama/email.
WITH config AS (
  SELECT lower(btrim('')) AS search_text
), matched_users AS (
  SELECT auth_user.id
  FROM auth.users auth_user
  LEFT JOIN public.profiles profile ON profile.id=auth_user.id
  CROSS JOIN config
  WHERE config.search_text=''
    OR (
      lower(COALESCE(auth_user.email,'')) LIKE '%'||config.search_text||'%'
      OR lower(COALESCE(profile.email,'')) LIKE '%'||config.search_text||'%'
      OR lower(COALESCE(profile.name,'')) LIKE '%'||config.search_text||'%'
    )
)
SELECT
  auth_user.id AS user_id,
  auth_user.email AS login_email,
  profile.email AS profile_email,
  profile.name AS account_name,
  profile.role AS legacy_profile_role,
  auth_user.email_confirmed_at,
  auth_user.last_sign_in_at,
  auth_user.created_at,
  COALESCE((
    SELECT string_agg(
      company.company_name||' | '||membership.role_code||' ('||membership.status||')',
      '; ' ORDER BY company.company_name,membership.company_id)
    FROM public.company_memberships membership
    JOIN public.companies company ON company.id=membership.company_id
    WHERE membership.user_id=auth_user.id
  ),'Belum memiliki akses Company') AS company_and_role,
  COALESCE((
    SELECT jsonb_agg(DISTINCT identity.provider ORDER BY identity.provider)
    FROM auth.identities identity
    WHERE identity.user_id=auth_user.id
  ),'[]'::JSONB) AS auth_providers,
  COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'companyId',membership.company_id,
      'companyCode',company.company_code,
      'companyName',company.company_name,
      'role',membership.role_code,
      'status',membership.status,
      'isDefault',membership.is_default_company
    ) ORDER BY company.company_name,membership.company_id)
    FROM public.company_memberships membership
    JOIN public.companies company ON company.id=membership.company_id
    WHERE membership.user_id=auth_user.id
  ),'[]'::JSONB) AS company_access
FROM matched_users matched
JOIN auth.users auth_user ON auth_user.id=matched.id
LEFT JOIN public.profiles profile ON profile.id=auth_user.id
ORDER BY lower(COALESCE(profile.name,auth_user.email,'')),auth_user.id;
