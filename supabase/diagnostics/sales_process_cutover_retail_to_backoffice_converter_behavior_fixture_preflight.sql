-- Read-only fixture preflight for the rollback-only Retail -> Backoffice converter behavior.
WITH candidates AS (
  SELECT company.id
  FROM public.companies company
  JOIN LATERAL(SELECT candidate.* FROM public.stores candidate
    WHERE candidate.company_id=company.id AND candidate.status='ACTIVE'
    ORDER BY candidate.id LIMIT 1) store ON true
  JOIN LATERAL(SELECT candidate.* FROM public.pos_terminals candidate
    WHERE candidate.company_id=company.id AND candidate.store_id=store.id
      AND candidate.status='ACTIVE'
    ORDER BY candidate.id LIMIT 1) terminal ON true
  JOIN LATERAL(SELECT candidate.* FROM public.warehouses candidate
    WHERE candidate.company_id=company.id AND candidate.is_active
      AND candidate.is_sale_source
      AND (candidate.store_id=store.id OR candidate.store_id IS NULL)
    ORDER BY (candidate.store_id=store.id) DESC,candidate.id LIMIT 1) warehouse ON true
  JOIN LATERAL(SELECT candidate.* FROM public.customers candidate
    WHERE candidate.company_id=company.id AND candidate.is_active
    ORDER BY candidate.is_system_customer DESC,candidate.id LIMIT 1) customer ON true
  JOIN LATERAL(SELECT candidate.id
    FROM public.product_uoms candidate
    JOIN public.products product ON product.company_id=candidate.company_id
      AND product.id=candidate.product_id AND product.is_active AND NOT product.is_bundle
    JOIN public.uoms uom ON uom.company_id=candidate.company_id
      AND uom.id=candidate.uom_id AND uom.is_active
    WHERE candidate.company_id=company.id AND candidate.is_active
      AND candidate.sales_allowed AND candidate.factor_to_base>0
      AND candidate.sale_price>0
      AND (private.resolve_pos_sale_price(company.id,store.id,customer.id,
        candidate.id,1,clock_timestamp())->>'resolvedUnitPrice')::numeric>0
    ORDER BY candidate.id LIMIT 1) product_uom ON true
  WHERE company.status='ACTIVE'
)
SELECT 'retail_to_backoffice_behavior_fixture' check_name,
  CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END status,
  CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint violation_rows,
  jsonb_build_object('eligibleCompanies',count(*)) details
FROM candidates;
