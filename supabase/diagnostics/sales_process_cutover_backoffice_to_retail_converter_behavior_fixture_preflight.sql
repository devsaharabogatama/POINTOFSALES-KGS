-- Read-only exact fixture gate for the Step 4C rollback-only behavior.
WITH actor_fixture AS (
  SELECT profile.id FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role
  ORDER BY profile.id LIMIT 1
), company_fixture AS MATERIALIZED (
  SELECT company.id,store.id store_id,customer.id customer_id,
    product_uom.id product_uom_id
  FROM public.companies company
  JOIN LATERAL(SELECT candidate.id FROM public.stores candidate
    WHERE candidate.company_id=company.id AND candidate.status='ACTIVE'
    ORDER BY candidate.id LIMIT 1) store ON true
  JOIN LATERAL(SELECT candidate.id FROM public.warehouses candidate
    WHERE candidate.company_id=company.id AND candidate.is_active AND candidate.is_sale_source
    ORDER BY candidate.id LIMIT 1) warehouse ON true
  JOIN LATERAL(SELECT candidate.id FROM public.customers candidate
    WHERE candidate.company_id=company.id AND candidate.is_active
    ORDER BY candidate.is_system_customer DESC,candidate.id LIMIT 1) customer ON true
  JOIN LATERAL(SELECT candidate.id FROM public.product_uoms candidate
    JOIN public.products product ON product.company_id=candidate.company_id
      AND product.id=candidate.product_id AND product.is_active AND NOT product.is_bundle
    JOIN public.uoms uom ON uom.company_id=candidate.company_id
      AND uom.id=candidate.uom_id AND uom.is_active
    WHERE candidate.company_id=company.id AND candidate.is_active
      AND candidate.sales_allowed AND candidate.factor_to_base>0
      AND candidate.sale_price>0
      AND (SELECT count(*) FROM public.product_uoms exact
        WHERE exact.company_id=candidate.company_id AND exact.product_id=candidate.product_id
          AND exact.uom_id=candidate.uom_id AND exact.is_active AND exact.sales_allowed)=1
    ORDER BY candidate.id LIMIT 1) product_uom ON true
  WHERE company.status='ACTIVE'
), resolved_fixture AS MATERIALIZED (
  SELECT fixture.*,
    private.resolve_pos_sale_price(fixture.id,fixture.store_id,fixture.customer_id,
      fixture.product_uom_id,1,clock_timestamp()) price_result
  FROM company_fixture fixture
)
SELECT 'step_4c_behavior_actor_fixture' check_name,
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
  abs(1-count(*))::bigint violation_rows,
  jsonb_build_object('linkedSuperAdminRows',count(*)) details FROM actor_fixture
UNION ALL
SELECT 'step_4c_behavior_company_fixture',
  CASE WHEN count(*) FILTER(WHERE (price_result->>'resolvedUnitPrice')::numeric>0)>0
    THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN count(*) FILTER(WHERE (price_result->>'resolvedUnitPrice')::numeric>0)>0
    THEN 0 ELSE 1 END::bigint,
  jsonb_build_object('rawCompanies',(SELECT count(*) FROM company_fixture),
    'eligibleCompanies',count(*) FILTER(
      WHERE (price_result->>'resolvedUnitPrice')::numeric>0))
FROM resolved_fixture;
