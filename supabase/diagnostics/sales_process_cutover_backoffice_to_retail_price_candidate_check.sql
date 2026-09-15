-- Read-only two-stage check: materialize canonical Product-UOM before invoking
-- the exception-raising price resolver.
WITH raw_candidates AS MATERIALIZED (
  SELECT company.id company_id,store.id store_id,customer.id customer_id,
    product_uom.id product_uom_id
  FROM public.companies company
  JOIN LATERAL(SELECT candidate.id FROM public.stores candidate
    WHERE candidate.company_id=company.id AND candidate.status='ACTIVE'
    ORDER BY candidate.id LIMIT 1) store ON true
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
), resolved AS MATERIALIZED (
  SELECT raw.*,
    private.resolve_pos_sale_price(raw.company_id,raw.store_id,raw.customer_id,
      raw.product_uom_id,1,clock_timestamp()) result
  FROM raw_candidates raw
)
SELECT 'step_4c_materialized_price_candidates' check_name,
  CASE WHEN count(*) FILTER(WHERE (result->>'resolvedUnitPrice')::numeric>0)>0
    THEN 'PASS' ELSE 'BLOCKER' END status,
  CASE WHEN count(*) FILTER(WHERE (result->>'resolvedUnitPrice')::numeric>0)>0
    THEN 0 ELSE 1 END::bigint violation_rows,
  jsonb_build_object('rawCandidates',(SELECT count(*) FROM raw_candidates),
    'positiveResolvedCandidates',count(*) FILTER(
      WHERE (result->>'resolvedUnitPrice')::numeric>0)) details
FROM resolved;
