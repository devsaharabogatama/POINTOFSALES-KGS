-- Step 4/6.2: separate Customer commercial disposition from physical shortage state.
-- Forward-only correction for applied 20260911164000. No operational receipt,
-- Stock, FIFO, Reservation, Invoice, Payment, or Finance mutation is activated.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911164000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: discrepancy contract foundation required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911165000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260911165000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  -- Runtime is not active yet. Refuse to invent physical facts for any row that
  -- may have been inserted outside the approved rollout.
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_discrepancy_lines)
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_discrepancies)
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_discrepancy_operations)
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_discrepancy_audit) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: discrepancy runtime rows require explicit reconciliation';
  END IF;
  IF EXISTS(SELECT 1 FROM information_schema.columns
    WHERE table_schema='public'
      AND table_name='backoffice_sales_delivery_discrepancy_lines'
      AND column_name IN('physical_state','actual_uom_id','actual_quantity_uom','actual_quantity_base'))
    OR to_regprocedure('private.classify_backoffice_sales_discrepancy(text,text,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: physical-state contract collision';
  END IF;
END
$guard$;

ALTER TABLE public.backoffice_sales_delivery_discrepancy_lines
  ADD COLUMN physical_state text,
  ADD COLUMN actual_uom_id uuid,
  ADD COLUMN actual_quantity_uom numeric(24,6),
  ADD COLUMN actual_quantity_base numeric(24,6),
  ADD CONSTRAINT backoffice_sales_delivery_discrepancy_lines_actual_uom_fk
    FOREIGN KEY(company_id,actual_uom_id)
    REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT;

ALTER TABLE public.backoffice_sales_delivery_discrepancy_lines
  DROP CONSTRAINT backoffice_sales_delivery_discrepancy_lines_type_check,
  DROP CONSTRAINT backoffice_sales_delivery_discrepancy_lines_resolution_check,
  DROP CONSTRAINT backoffice_sales_delivery_discrepancy_lines_warehouse_check;

ALTER TABLE public.backoffice_sales_delivery_discrepancy_lines
  ADD CONSTRAINT backoffice_sales_delivery_discrepancy_lines_type_check CHECK(
    discrepancy_type IN('SHORT','OVERAGE','WRONG_ITEM')
    AND ((discrepancy_type='WRONG_ITEM'
      AND actual_product_id IS NOT NULL
      AND actual_uom_id IS NOT NULL
      AND actual_quantity_uom>0
      AND actual_quantity_base>0
      AND actual_product_id<>expected_product_id)
    OR (discrepancy_type<>'WRONG_ITEM'
      AND actual_product_id IS NULL
      AND actual_uom_id IS NULL
      AND actual_quantity_uom IS NULL
      AND actual_quantity_base IS NULL))),
  ADD CONSTRAINT backoffice_sales_delivery_discrepancy_lines_physical_check CHECK(
    (discrepancy_type='SHORT'
      AND physical_state IN('NOT_LOADED','RETURNING','LOST','DAMAGED'))
    OR (discrepancy_type<>'SHORT' AND physical_state IS NULL)),
  ADD CONSTRAINT backoffice_sales_delivery_discrepancy_lines_resolution_check CHECK(
    (discrepancy_type='SHORT' AND requested_resolution IN('BACKORDER','ACCEPT_SHORT'))
    OR (discrepancy_type='OVERAGE'
      AND requested_resolution IN('ACCEPT_OVERAGE','RETURN_OVERAGE'))
    OR (discrepancy_type='WRONG_ITEM'
      AND requested_resolution='REPLACE_WRONG_ITEM')),
  ADD CONSTRAINT backoffice_sales_delivery_discrepancy_lines_warehouse_check CHECK(
    (discrepancy_type='SHORT'
      AND warehouse_resolution_status IN('PENDING','RESOLVED','REJECTED'))
    OR (requested_resolution IN('RETURN_OVERAGE','REPLACE_WRONG_ITEM')
      AND warehouse_resolution_status IN('PENDING','RESOLVED','REJECTED'))
    OR (discrepancy_type<>'SHORT'
      AND requested_resolution NOT IN('RETURN_OVERAGE','REPLACE_WRONG_ITEM')
      AND warehouse_resolution_status='NOT_REQUIRED'));

CREATE FUNCTION private.classify_backoffice_sales_discrepancy(
  p_discrepancy_type text,p_requested_resolution text,p_physical_state text
) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE
SET search_path=public,pg_temp AS $$
DECLARE
  v_type text:=upper(btrim(COALESCE(p_discrepancy_type,'')));
  v_resolution text:=upper(btrim(COALESCE(p_requested_resolution,'')));
  v_physical text:=NULLIF(upper(btrim(COALESCE(p_physical_state,''))), '');
  v_valid boolean:=false;v_sales boolean:=false;v_warehouse boolean:=false;
BEGIN
  v_valid:=CASE v_type
    WHEN 'SHORT' THEN v_resolution IN('BACKORDER','ACCEPT_SHORT')
      AND v_physical IN('NOT_LOADED','RETURNING','LOST','DAMAGED')
    WHEN 'OVERAGE' THEN v_resolution IN('ACCEPT_OVERAGE','RETURN_OVERAGE')
      AND v_physical IS NULL
    WHEN 'WRONG_ITEM' THEN v_resolution='REPLACE_WRONG_ITEM'
      AND v_physical IS NULL
    ELSE false END;
  IF v_type='SHORT' AND v_resolution IN('BACKORDER','ACCEPT_SHORT')
    AND v_physical IS NULL THEN
    RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_PHYSICAL_STATE_REQUIRED';
  END IF;
  IF NOT v_valid THEN RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_ACTION_INVALID'; END IF;
  v_sales:=v_resolution='ACCEPT_OVERAGE';
  -- Every shortage remains Warehouse-visible because its dispatched Transit
  -- quantity must be reconciled separately from the Customer decision.
  v_warehouse:=v_type='SHORT'
    OR v_resolution IN('RETURN_OVERAGE','REPLACE_WRONG_ITEM');
  RETURN jsonb_build_object('discrepancyType',v_type,
    'requestedResolution',v_resolution,'physicalState',v_physical,
    'requiresSalesApproval',v_sales,
    'requiresWarehouseResolution',v_warehouse);
END
$$;

CREATE OR REPLACE FUNCTION private.classify_backoffice_sales_discrepancy(
  p_discrepancy_type text,p_requested_resolution text
) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE
SET search_path=public,pg_temp AS $$
BEGIN
  RETURN private.classify_backoffice_sales_discrepancy(
    p_discrepancy_type,p_requested_resolution,NULL);
END
$$;

CREATE OR REPLACE FUNCTION private.validate_backoffice_sales_receipt_disposition_payload(
  p_lines jsonb
) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE
SET search_path=public,pg_temp AS $$
DECLARE
  v_line jsonb;v_item jsonb;v_class jsonb;v_line_id uuid;
  v_actual_product_id uuid;v_actual_uom_id uuid;
  v_accepted numeric;v_qty numeric;v_actual_qty_uom numeric;v_actual_qty_base numeric;
  v_discrepancy numeric:=0;v_total_accepted numeric:=0;
  v_actual_wrong numeric:=0;v_sales boolean:=false;v_warehouse boolean:=false;
  v_count integer:=0;v_seen uuid[]:='{}'::uuid[];
BEGIN
  IF jsonb_typeof(p_lines)<>'array' OR jsonb_array_length(p_lines)=0
    OR jsonb_array_length(p_lines)>500 THEN
    RAISE EXCEPTION 'BACKOFFICE_RECEIPT_DISPOSITION_LINES_INVALID';
  END IF;
  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines)
  LOOP
    IF jsonb_typeof(v_line)<>'object' THEN
      RAISE EXCEPTION 'BACKOFFICE_RECEIPT_DISPOSITION_LINES_INVALID';
    END IF;
    BEGIN v_line_id:=(v_line->>'deliveryLineId')::uuid;
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_RECEIPT_DISPOSITION_LINE_ID_INVALID'; END;
    IF v_line_id IS NULL THEN RAISE EXCEPTION 'BACKOFFICE_RECEIPT_DISPOSITION_LINE_ID_INVALID'; END IF;
    IF v_line_id=ANY(v_seen) THEN RAISE EXCEPTION 'BACKOFFICE_RECEIPT_DISPOSITION_LINE_DUPLICATE'; END IF;
    v_seen:=array_append(v_seen,v_line_id);
    BEGIN v_accepted:=(v_line->>'acceptedBaseQty')::numeric;
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_RECEIPT_ACCEPTED_QUANTITY_INVALID'; END;
    IF v_accepted IS NULL OR v_accepted<0 THEN
      RAISE EXCEPTION 'BACKOFFICE_RECEIPT_ACCEPTED_QUANTITY_INVALID';
    END IF;
    v_total_accepted:=v_total_accepted+v_accepted;
    IF COALESCE(jsonb_typeof(v_line->'discrepancies'),'array')<>'array' THEN
      RAISE EXCEPTION 'BACKOFFICE_RECEIPT_DISCREPANCY_LINES_INVALID';
    END IF;
    FOR v_item IN SELECT value
      FROM jsonb_array_elements(COALESCE(v_line->'discrepancies','[]'::jsonb))
    LOOP
      IF jsonb_typeof(v_item)<>'object' THEN
        RAISE EXCEPTION 'BACKOFFICE_RECEIPT_DISCREPANCY_LINES_INVALID';
      END IF;
      BEGIN v_qty:=(v_item->>'quantityBase')::numeric;
      EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_QUANTITY_INVALID'; END;
      IF v_qty IS NULL OR v_qty<=0 THEN
        RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_QUANTITY_INVALID';
      END IF;
      v_class:=private.classify_backoffice_sales_discrepancy(
        v_item->>'discrepancyType',v_item->>'requestedResolution',
        v_item->>'physicalState');
      IF v_class->>'discrepancyType'='WRONG_ITEM' THEN
        BEGIN
          v_actual_product_id:=(v_item->>'actualProductId')::uuid;
          v_actual_uom_id:=(v_item->>'actualUomId')::uuid;
          v_actual_qty_uom:=(v_item->>'actualQuantityUom')::numeric;
          v_actual_qty_base:=(v_item->>'actualQuantityBase')::numeric;
        EXCEPTION WHEN OTHERS THEN
          RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_ACTUAL_ITEM_INVALID';
        END;
        IF v_actual_product_id IS NULL OR v_actual_uom_id IS NULL
          OR v_actual_qty_uom IS NULL OR v_actual_qty_uom<=0
          OR v_actual_qty_base IS NULL OR v_actual_qty_base<=0 THEN
          RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_ACTUAL_ITEM_REQUIRED';
        END IF;
        v_actual_wrong:=v_actual_wrong+v_actual_qty_base;
      ELSIF NULLIF(btrim(v_item->>'actualProductId'),'') IS NOT NULL
        OR NULLIF(btrim(v_item->>'actualUomId'),'') IS NOT NULL
        OR NULLIF(btrim(v_item->>'actualQuantityUom'),'') IS NOT NULL
        OR NULLIF(btrim(v_item->>'actualQuantityBase'),'') IS NOT NULL THEN
        RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_ACTUAL_ITEM_NOT_ALLOWED';
      END IF;
      v_discrepancy:=v_discrepancy+v_qty;v_count:=v_count+1;
      v_sales:=v_sales OR (v_class->>'requiresSalesApproval')::boolean;
      v_warehouse:=v_warehouse OR (v_class->>'requiresWarehouseResolution')::boolean;
    END LOOP;
  END LOOP;
  IF v_total_accepted<=0 AND v_discrepancy<=0 THEN
    RAISE EXCEPTION 'BACKOFFICE_RECEIPT_DISPOSITION_EMPTY';
  END IF;
  RETURN jsonb_build_object('lineCount',jsonb_array_length(p_lines),
    'discrepancyCount',v_count,'acceptedBaseQty',v_total_accepted,
    'discrepancyBaseQty',v_discrepancy,
    'actualWrongItemBaseQty',v_actual_wrong,
    'requiresSalesApproval',v_sales,
    'requiresWarehouseResolution',v_warehouse);
END
$$;

REVOKE ALL ON FUNCTION private.classify_backoffice_sales_discrepancy(text,text,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.classify_backoffice_sales_discrepancy(text,text,text)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260911165000','backoffice_sales_discrepancy_physical_state',
  'Step 4/6.2 separates shortage commercial resolution from explicit physical state and stores independent actual wrong-item Product/UOM/quantity; zero operational effect');

NOTIFY pgrst,'reload schema';
COMMIT;
