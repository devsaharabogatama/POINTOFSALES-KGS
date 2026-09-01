-- Allow the Inventory-owned Surat Jalan read/print channel to consume both
-- legacy POSTED Sale documents and ODR confirmed-order snapshots.
BEGIN;

DO $guard$
DECLARE v_read_definition TEXT;v_print_definition TEXT;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260901110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260901110000';
  END IF;
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version=ANY(ARRAY[
        '20260813150000','20260827153000','20260828130000']))<>3 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Inventory Delivery/ODR document chain incomplete';
  END IF;
  IF to_regprocedure('public.get_inventory_delivery_document(uuid)') IS NULL
    OR to_regprocedure('public.record_inventory_delivery_print(uuid)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Inventory Delivery RPC missing';
  END IF;
  SELECT pg_get_functiondef('public.get_inventory_delivery_document(uuid)'::regprocedure)
    INTO v_read_definition;
  SELECT pg_get_functiondef('public.record_inventory_delivery_print(uuid)'::regprocedure)
    INTO v_print_definition;
  IF v_read_definition NOT LIKE '%acp5e_get_sales_delivery_document_core%'
    OR v_print_definition NOT LIKE '%acp5e_record_sales_document_print_core%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Inventory Delivery RPC drift';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION public.get_inventory_delivery_document(p_sales_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_result JSONB;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.delivery_documents','VIEW');
  SELECT jsonb_build_object(
    'deliveryDocumentId',delivery.id,
    'deliveryNo',delivery.delivery_no,
    'status',delivery.status,
    'masterVersion',delivery.master_version,
    'snapshot',delivery.snapshot_payload,
    'fulfillmentMode',delivery.fulfillment_mode,
    'lines',COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'lineNo',line.line_no,'sku',line.product_sku_snapshot,
        'productName',line.product_name_snapshot,
        'uomName',line.sale_uom_name_snapshot,
        'quantity',line.quantity_uom
      ) ORDER BY line.line_no)
      FROM public.sales_delivery_lines line
      WHERE line.company_id=delivery.company_id
        AND line.delivery_document_id=delivery.id
    ),'[]'::JSONB)
  ) INTO v_result
  FROM public.sales_delivery_documents delivery
  WHERE delivery.company_id=v_company AND delivery.sales_id=p_sales_id;
  IF v_result IS NULL THEN RAISE EXCEPTION 'SALES_DELIVERY_NOT_FOUND'; END IF;
  RETURN v_result;
END
$$;

CREATE OR REPLACE FUNCTION public.record_inventory_delivery_print(
  p_delivery_document_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_sales UUID;v_number TEXT;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.delivery_documents','VIEW');
  SELECT delivery.sales_id,delivery.delivery_no INTO v_sales,v_number
  FROM public.sales_delivery_documents delivery
  WHERE delivery.company_id=v_company AND delivery.id=p_delivery_document_id;
  IF v_sales IS NULL THEN RAISE EXCEPTION 'SALES_DELIVERY_NOT_FOUND'; END IF;
  INSERT INTO public.sales_document_audit(
    company_id,document_type,document_id,sales_id,action,actor_id,
    before_state,after_state
  ) VALUES(v_company,'SALES_DELIVERY',p_delivery_document_id,v_sales,
    'PRINT',v_actor,NULL,jsonb_build_object('documentNo',v_number));
  RETURN jsonb_build_object('documentNo',v_number,'printRecorded',TRUE);
END
$$;

REVOKE ALL ON FUNCTION public.get_inventory_delivery_document(UUID),
  public.record_inventory_delivery_print(UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_delivery_document(UUID),
  public.record_inventory_delivery_print(UUID) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260901110000','inventory_delivery_odr_print_compatibility',
  'Inventory VIEW-guarded Surat Jalan detail and print audit now read immutable Delivery snapshots directly for both legacy and ODR confirmed orders; no operational data backfill');

COMMIT;
