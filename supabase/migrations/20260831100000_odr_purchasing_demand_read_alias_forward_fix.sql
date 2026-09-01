-- Repair the ODR Purchasing composed read after the outer aggregate referenced
-- the inner-only `product` alias. This migration is read-model only: it does
-- not mutate Demand, Stock Request, Supplier Order, Stock, or Finance data.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828190000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-4D managed request runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260831100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260831100000';
  END IF;
  IF to_regprocedure('public.get_purchase_procurement_demands()') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Purchasing demand read RPC required';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION public.get_purchase_procurement_demands()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_base JSONB;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','VIEW');
  v_base:=jsonb_build_object('companyId',v_company,
    'demands',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.updated_at DESC,row_data.id),'[]'::JSONB)
      FROM (SELECT demand.id,demand.store_id,store.store_name,
          demand.warehouse_id,warehouse.name warehouse_name,
          demand.cashier_session_id,session.session_code,demand.status,
          demand.total_demand_base_qty,demand.total_released_base_qty,
          demand.stock_request_document_id,demand.master_version,
          demand.session_closed_at,demand.created_at,demand.updated_at
        FROM public.sales_order_procurement_demands demand
        JOIN public.stores store ON store.company_id=demand.company_id
          AND store.id=demand.store_id
        JOIN public.warehouses warehouse ON warehouse.company_id=demand.company_id
          AND warehouse.id=demand.warehouse_id
        JOIN public.cashier_sessions session ON session.company_id=demand.company_id
          AND session.id=demand.cashier_session_id
        WHERE demand.company_id=v_company
        ORDER BY demand.updated_at DESC,demand.id LIMIT 500) row_data),
    'lines',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.demand_id,row_data.product_name,row_data.id),'[]'::JSONB)
      FROM (SELECT line.id,line.demand_id,line.sales_id,line.reservation_line_id,
          line.stock_product_id,product.sku product_sku,product.name product_name,
          line.warehouse_id,line.demand_base_qty,line.released_base_qty,
          line.demand_base_qty-line.released_base_qty open_demand_base_qty,
          line.stock_request_line_id,line.status,line.master_version,line.updated_at
        FROM public.sales_order_procurement_demand_lines line
        JOIN public.products product ON product.company_id=line.company_id
          AND product.id=line.stock_product_id
        WHERE line.company_id=v_company
        ORDER BY line.demand_id,product.name,line.id LIMIT 10000) row_data));
  RETURN v_base||jsonb_build_object('amendments',(SELECT COALESCE(jsonb_agg(
      to_jsonb(amendment) ORDER BY amendment.updated_at DESC,amendment.id),
      '[]'::JSONB)
    FROM public.sales_order_procurement_amendments amendment
    WHERE amendment.company_id=v_company));
END
$$;

REVOKE ALL ON FUNCTION public.get_purchase_procurement_demands()
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_purchase_procurement_demands()
TO authenticated,service_role;

DO $verify$
DECLARE v_definition TEXT;
BEGIN
  SELECT pg_get_functiondef(
    'public.get_purchase_procurement_demands()'::regprocedure)
  INTO v_definition;
  IF v_definition !~
       'ORDER BY[[:space:]]+row_data\.demand_id[[:space:]]*,[[:space:]]*row_data\.product_name[[:space:]]*,[[:space:]]*row_data\.id'
     OR v_definition ~
       'ORDER BY[[:space:]]+row_data\.demand_id[[:space:]]*,[[:space:]]*product\.name[[:space:]]*,[[:space:]]*row_data\.id' THEN
    RAISE EXCEPTION 'MIGRATION_POSTCONDITION_FAILED: Purchasing demand read alias';
  END IF;
END
$verify$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260831100000','odr_purchasing_demand_read_alias_forward_fix',
  'Repair the composed Purchasing demand line aggregate to order through the visible row_data.product_name alias; no data backfill or business mutation');

NOTIFY pgrst,'reload schema';
COMMIT;
