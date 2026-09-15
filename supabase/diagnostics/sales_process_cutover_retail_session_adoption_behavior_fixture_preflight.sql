-- Read-only exact fixture gate for Step 4D behavior.
WITH raw_fixture AS MATERIALIZED (
  SELECT company.id company_id,store.id store_id,customer.id customer_id,
    product_uom.id product_uom_id
  FROM public.companies company
  JOIN LATERAL(SELECT candidate.id FROM public.stores candidate
    WHERE candidate.company_id=company.id AND candidate.status='ACTIVE'
    ORDER BY candidate.id LIMIT 1) store ON true
  JOIN LATERAL(SELECT candidate.id FROM public.pos_terminals candidate
    WHERE candidate.company_id=company.id AND candidate.store_id=store.id
      AND candidate.status='ACTIVE' ORDER BY candidate.id LIMIT 1) terminal ON true
  JOIN LATERAL(SELECT candidate.id FROM public.warehouses candidate
    WHERE candidate.company_id=company.id AND candidate.is_active AND candidate.is_sale_source
      AND (candidate.store_id=store.id OR candidate.store_id IS NULL)
    ORDER BY (candidate.store_id=store.id) DESC,candidate.id LIMIT 1) warehouse ON true
  JOIN LATERAL(SELECT candidate.id FROM public.customers candidate
    WHERE candidate.company_id=company.id AND candidate.is_active
    ORDER BY candidate.is_system_customer DESC,candidate.id LIMIT 1) customer ON true
  JOIN LATERAL(SELECT candidate.id FROM public.product_uoms candidate
    JOIN public.products product ON product.company_id=candidate.company_id
      AND product.id=candidate.product_id AND product.is_active AND NOT product.is_bundle
    JOIN public.uoms uom ON uom.company_id=candidate.company_id
      AND uom.id=candidate.uom_id AND uom.is_active
    WHERE candidate.company_id=company.id AND candidate.is_active
      AND candidate.sales_allowed AND candidate.factor_to_base>0 AND candidate.sale_price>0
    ORDER BY candidate.id LIMIT 1) product_uom ON true
  JOIN LATERAL(SELECT candidate.id FROM public.payment_methods candidate
    WHERE candidate.company_id=company.id AND candidate.is_active
      AND candidate.effective_from<=clock_timestamp()
      AND (candidate.effective_to IS NULL OR candidate.effective_to>=clock_timestamp())
      AND candidate.proof_mode<>'REQUIRED'
      AND candidate.settlement_route<>'INTERNAL_LIABILITY'
      AND candidate.method_type::text NOT IN('CUSTOMER_BALANCE','KETUL_OFFSET','TEMPO')
      AND (candidate.available_all_stores OR EXISTS(SELECT 1
        FROM public.payment_method_store_assignments assignment
        WHERE assignment.company_id=candidate.company_id
          AND assignment.payment_method_id=candidate.id AND assignment.store_id=store.id))
    ORDER BY candidate.is_default DESC,candidate.id LIMIT 1) payment_method ON true
  WHERE company.status='ACTIVE'
), resolved_fixture AS MATERIALIZED (
  SELECT fixture.*,private.resolve_pos_sale_price(fixture.company_id,fixture.store_id,
    fixture.customer_id,fixture.product_uom_id,1,clock_timestamp()) price_result
  FROM raw_fixture fixture
)
SELECT 'step_4d_behavior_actor_fixture' check_name,
  CASE WHEN to_regclass('auth.users') IS NOT NULL AND to_regclass('public.profiles') IS NOT NULL
    THEN 'PASS' ELSE 'BLOCKER' END status,
  CASE WHEN to_regclass('auth.users') IS NOT NULL AND to_regclass('public.profiles') IS NOT NULL
    THEN 0 ELSE 1 END::bigint violation_rows,
  jsonb_build_object('testCreatesFreshAuthActor',true,
    'operationalActorOrSessionRequired',false,'transactionEnd','ROLLBACK') details
UNION ALL
SELECT 'step_4d_behavior_master_fixture',
  CASE WHEN count(*) FILTER(WHERE (price_result->>'resolvedUnitPrice')::numeric>0)>0
    THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN count(*) FILTER(WHERE (price_result->>'resolvedUnitPrice')::numeric>0)>0
    THEN 0 ELSE 1 END::bigint,
  jsonb_build_object('rawCompanies',(SELECT count(*) FROM raw_fixture),
    'eligibleCompanies',count(*) FILTER(WHERE (price_result->>'resolvedUnitPrice')::numeric>0))
FROM resolved_fixture;
