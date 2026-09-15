-- SELECT-only verification of the exact rollback fixture used by persistent
-- cutover preview behavior. Entitlement is enabled only inside its transaction.
WITH linked_actor AS (
  SELECT profile.id FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role
), company_fixture AS (
  SELECT DISTINCT setting.company_id
  FROM public.company_sales_process_settings setting
  JOIN public.companies company ON company.id=setting.company_id AND company.status='ACTIVE'
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=company.id
    AND warehouse.is_active AND warehouse.is_sale_source
    AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
  JOIN public.customers customer ON customer.company_id=company.id AND customer.is_active
), checks AS (
  SELECT 'persistent_preview_behavior_linked_actor'::text check_name,
    CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END status,
    CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('linkedSuperAdminRows',count(*)) details FROM linked_actor
  UNION ALL
  SELECT 'persistent_preview_behavior_company_fixture',
    CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('eligibleCompanies',count(*),
      'entitlementPreparation','rollback-only behavior transaction')
  FROM company_fixture
)
SELECT * FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 ELSE 2 END,check_name;
