-- Read-only fixture preflight for unified_warehouse_negative_stock_authority_behavior.sql.
WITH candidates AS (
  SELECT company.id company_id
  FROM public.companies company
  JOIN LATERAL (
    SELECT candidate.* FROM public.stores candidate
    WHERE candidate.company_id=company.id AND candidate.status='ACTIVE'
    ORDER BY candidate.id LIMIT 1
  ) store ON true
  JOIN LATERAL (
    SELECT candidate.* FROM public.pos_terminals candidate
    WHERE candidate.company_id=company.id AND candidate.store_id=store.id
      AND candidate.status='ACTIVE'
    ORDER BY candidate.id LIMIT 1
  ) terminal ON true
  JOIN LATERAL (
    SELECT candidate.* FROM public.warehouses candidate
    WHERE candidate.company_id=company.id AND candidate.is_active
      AND candidate.is_sale_source
      AND (candidate.store_id=store.id OR candidate.store_id IS NULL)
    ORDER BY (candidate.store_id=store.id) DESC,candidate.id LIMIT 1
  ) warehouse ON true
  JOIN LATERAL (
    SELECT candidate.* FROM public.customers candidate
    WHERE candidate.company_id=company.id AND candidate.is_active
    ORDER BY candidate.is_system_customer DESC,candidate.id LIMIT 1
  ) customer ON true
  JOIN LATERAL (
    SELECT product_candidate.id,uom_candidate.id product_uom_id
    FROM public.products product_candidate
    JOIN public.product_uoms uom_candidate
      ON uom_candidate.company_id=product_candidate.company_id
     AND uom_candidate.product_id=product_candidate.id
    JOIN public.uoms unit ON unit.company_id=uom_candidate.company_id
      AND unit.id=uom_candidate.uom_id
    WHERE product_candidate.company_id=company.id
      AND product_candidate.is_active AND NOT product_candidate.is_bundle
      AND uom_candidate.is_active AND uom_candidate.sales_allowed
      AND uom_candidate.factor_to_base>0
      AND uom_candidate.sale_price IS NOT NULL AND uom_candidate.sale_price>0
      AND unit.is_active
      AND (private.resolve_pos_sale_price(company.id,store.id,customer.id,
        uom_candidate.id,1,clock_timestamp())->>'resolvedUnitPrice')::numeric>0
      AND COALESCE((SELECT stock.stock_qty FROM public.product_stocks stock
        WHERE stock.company_id=company.id AND stock.warehouse_id=warehouse.id
          AND stock.product_id=product_candidate.id),0)>=0
      AND NOT EXISTS(SELECT 1 FROM public.pos_offline_stock_allowances allowance
        WHERE allowance.company_id=company.id
          AND allowance.warehouse_id=warehouse.id
          AND allowance.product_id=product_candidate.id
          AND allowance.status='ACTIVE'
          AND allowance.allocated_base_qty>allowance.consumed_base_qty)
    ORDER BY product_candidate.id,uom_candidate.id LIMIT 1
  ) product ON true
  JOIN LATERAL (
    SELECT candidate.* FROM public.payment_methods candidate
    WHERE candidate.company_id=company.id AND candidate.is_active
      AND candidate.effective_from<=clock_timestamp()
      AND (candidate.effective_to IS NULL OR candidate.effective_to>=clock_timestamp())
      AND candidate.proof_mode<>'REQUIRED'
      AND candidate.settlement_route<>'INTERNAL_LIABILITY'
      AND candidate.method_type::text NOT IN('CUSTOMER_BALANCE','KETUL_OFFSET','TEMPO')
      AND private.odr5d_settlement_account_function(candidate) IS NOT NULL
      AND (candidate.available_all_stores OR EXISTS(
        SELECT 1 FROM public.payment_method_store_assignments assignment
        WHERE assignment.company_id=candidate.company_id
          AND assignment.payment_method_id=candidate.id
          AND assignment.store_id=store.id))
    ORDER BY (candidate.method_type::text='CASH') DESC,
      candidate.is_default DESC,candidate.id LIMIT 1
  ) payment_method ON true
  WHERE company.status='ACTIVE'
)
SELECT 'unified_warehouse_negative_stock_behavior_fixture' check_name,
  CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END status,
  CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint violation_rows,
  jsonb_build_object('eligibleCompanies',count(*)) details
FROM candidates;
