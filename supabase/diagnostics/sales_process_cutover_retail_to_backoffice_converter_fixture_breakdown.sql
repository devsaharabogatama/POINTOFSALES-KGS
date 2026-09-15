-- Read-only breakdown for the Retail -> Backoffice behavioral fixture.
WITH companies AS (
  SELECT company.id
  FROM public.companies company
  WHERE company.status='ACTIVE'
), facts AS (
  SELECT company.id,
    EXISTS(SELECT 1 FROM public.stores store
      WHERE store.company_id=company.id AND store.status='ACTIVE') active_store,
    EXISTS(SELECT 1 FROM public.stores store
      JOIN public.pos_terminals terminal ON terminal.company_id=store.company_id
        AND terminal.store_id=store.id AND terminal.status='ACTIVE'
      WHERE store.company_id=company.id AND store.status='ACTIVE') active_store_terminal,
    EXISTS(SELECT 1 FROM public.stores store
      JOIN public.pos_terminals terminal ON terminal.company_id=store.company_id
        AND terminal.store_id=store.id AND terminal.status='ACTIVE'
      JOIN public.warehouses warehouse ON warehouse.company_id=store.company_id
        AND warehouse.is_active AND warehouse.is_sale_source
        AND (warehouse.store_id=store.id OR warehouse.store_id IS NULL)
      WHERE store.company_id=company.id AND store.status='ACTIVE') compatible_warehouse,
    EXISTS(SELECT 1 FROM public.customers customer
      WHERE customer.company_id=company.id AND customer.is_active) active_customer,
    EXISTS(SELECT 1 FROM public.company_features feature
      WHERE feature.company_id=company.id
        AND feature.feature_code='backoffice_delivered_qty_sales_enabled') feature_row,
    EXISTS(SELECT 1 FROM public.product_uoms product_uom
      JOIN public.products product ON product.company_id=product_uom.company_id
        AND product.id=product_uom.product_id AND product.is_active AND NOT product.is_bundle
      JOIN public.uoms uom ON uom.company_id=product_uom.company_id
        AND uom.id=product_uom.uom_id AND uom.is_active
      WHERE product_uom.company_id=company.id AND product_uom.is_active
        AND product_uom.sales_allowed AND product_uom.factor_to_base>0
        AND product_uom.sale_price>0) raw_product_uom
  FROM companies company
)
SELECT 'retail_to_backoffice_fixture_breakdown' check_name,'INFO' status,
  0::bigint violation_rows,
  jsonb_build_object('companies',COALESCE(jsonb_agg(jsonb_build_object(
    'companyId',id,'activeStore',active_store,
    'activeStoreTerminal',active_store_terminal,'compatibleWarehouse',compatible_warehouse,
    'activeCustomer',active_customer,'featureRow',feature_row,
    'rawPositiveProductUom',raw_product_uom) ORDER BY id),'[]'::jsonb)) details
FROM facts;
