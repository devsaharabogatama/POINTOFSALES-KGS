-- PRD: authorized POS negative Stock -> one submitted Stock Request per Cashier Session.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260814170000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Finance operational closure required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260819170000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260819170000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.negative_stock_sale_allocations allocation
    LEFT JOIN public.sales_headers sale
      ON sale.company_id=allocation.company_id AND sale.id=allocation.sales_id
    LEFT JOIN public.cashier_sessions session
      ON session.company_id=sale.company_id
     AND session.id=COALESCE(sale.posted_session_id,sale.session_id)
    WHERE sale.id IS NULL OR session.id IS NULL
      OR allocation.warehouse_id IS DISTINCT FROM session.sales_warehouse_id) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: invalid negative Stock Session lineage';
  END IF;
END
$guard$;

ALTER TABLE public.cashier_session_stock_snapshots
  DROP CONSTRAINT cashier_session_stock_snapshot_qty_nonnegative,
  ADD CONSTRAINT cashier_session_stock_snapshot_qty_numeric
    CHECK(stock_qty_base<>'NaN'::NUMERIC);

ALTER TABLE public.stock_request_documents
  ADD COLUMN request_source TEXT NOT NULL DEFAULT 'MANUAL',
  ADD CONSTRAINT stock_request_documents_source_check CHECK(
    request_source IN('MANUAL','NEGATIVE_STOCK_SESSION_CLOSE')
  );

CREATE UNIQUE INDEX uq_stock_request_negative_session
  ON public.stock_request_documents(company_id,requesting_session_id)
  WHERE request_source='NEGATIVE_STOCK_SESSION_CLOSE';

CREATE TABLE public.stock_request_negative_allocations(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL,
  stock_request_document_id UUID NOT NULL,
  stock_request_line_id UUID NOT NULL,
  negative_stock_sale_allocation_id UUID NOT NULL,
  requested_base_qty NUMERIC(24,6) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT stock_request_negative_alloc_company_id_id_unique
    UNIQUE(company_id,id),
  CONSTRAINT stock_request_negative_alloc_source_unique
    UNIQUE(company_id,negative_stock_sale_allocation_id),
  CONSTRAINT stock_request_negative_alloc_qty_positive
    CHECK(requested_base_qty>0),
  CONSTRAINT fk_stock_request_negative_alloc_document
    FOREIGN KEY(company_id,stock_request_document_id)
    REFERENCES public.stock_request_documents(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_stock_request_negative_alloc_line
    FOREIGN KEY(company_id,stock_request_line_id)
    REFERENCES public.stock_request_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_stock_request_negative_alloc_source
    FOREIGN KEY(company_id,negative_stock_sale_allocation_id)
    REFERENCES public.negative_stock_sale_allocations(company_id,id)
    ON DELETE RESTRICT
);

CREATE INDEX idx_stock_request_negative_alloc_document
  ON public.stock_request_negative_allocations(
    company_id,stock_request_document_id,stock_request_line_id
  );

CREATE FUNCTION private.trg_prd_guard_negative_stock_request_lineage()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP<>'INSERT' THEN
    RAISE EXCEPTION 'NEGATIVE_STOCK_REQUEST_LINEAGE_IMMUTABLE';
  END IF;
  IF NOT EXISTS(SELECT 1
    FROM public.stock_request_documents document
    JOIN public.stock_request_lines line
      ON line.company_id=document.company_id
     AND line.document_id=document.id
     AND line.id=NEW.stock_request_line_id
    JOIN public.negative_stock_sale_allocations allocation
      ON allocation.company_id=document.company_id
     AND allocation.id=NEW.negative_stock_sale_allocation_id
     AND allocation.stock_product_id=line.product_id
    JOIN public.sales_headers sale
      ON sale.company_id=allocation.company_id AND sale.id=allocation.sales_id
    WHERE document.company_id=NEW.company_id
      AND document.id=NEW.stock_request_document_id
      AND document.request_source='NEGATIVE_STOCK_SESSION_CLOSE'
      AND document.status='DRAFT'
      AND COALESCE(sale.posted_session_id,sale.session_id)
        =document.requesting_session_id
      AND NEW.requested_base_qty
        =allocation.shortage_base_qty-allocation.replenished_base_qty
  ) THEN
    RAISE EXCEPTION 'INVALID_NEGATIVE_STOCK_REQUEST_LINEAGE';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER prd_guard_negative_stock_request_lineage
BEFORE INSERT OR UPDATE OR DELETE ON public.stock_request_negative_allocations
FOR EACH ROW EXECUTE FUNCTION
  private.trg_prd_guard_negative_stock_request_lineage();

CREATE FUNCTION private.trg_prd_guard_automatic_stock_request()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.request_source IS DISTINCT FROM OLD.request_source THEN
    RAISE EXCEPTION 'STOCK_REQUEST_SOURCE_IMMUTABLE';
  END IF;
  IF OLD.request_source='NEGATIVE_STOCK_SESSION_CLOSE'
     AND NEW.status='CANCELED' THEN
    RAISE EXCEPTION 'AUTOMATIC_NEGATIVE_STOCK_REQUEST_CANNOT_BE_CANCELED';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER prd_guard_automatic_stock_request
BEFORE UPDATE ON public.stock_request_documents
FOR EACH ROW EXECUTE FUNCTION private.trg_prd_guard_automatic_stock_request();

CREATE FUNCTION private.ensure_negative_session_stock_request(
  p_company_id UUID,p_cashier_session_id UUID,p_actor_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_session public.cashier_sessions%ROWTYPE;
  v_document public.stock_request_documents%ROWTYPE;
  v_product RECORD;v_allocation RECORD;
  v_document_id UUID;v_line_id UUID;v_request_no TEXT;
  v_line_no INTEGER:=0;v_line_count INTEGER:=0;
  v_total NUMERIC(24,6):=0;v_now TIMESTAMPTZ:=clock_timestamp();
  v_draft JSONB;v_submitted JSONB;
BEGIN
  SELECT * INTO v_session FROM public.cashier_sessions session
  WHERE session.company_id=p_company_id AND session.id=p_cashier_session_id
    AND session.cashier_id=p_actor_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CASHIER_SESSION_NOT_FOUND'; END IF;

  SELECT * INTO v_document FROM public.stock_request_documents document
  WHERE document.company_id=p_company_id
    AND document.requesting_session_id=p_cashier_session_id
    AND document.request_source='NEGATIVE_STOCK_SESSION_CLOSE';
  IF FOUND THEN
    RETURN jsonb_build_object(
      'stockRequestId',v_document.id,'stockRequestNo',v_document.request_no,
      'stockRequestStatus',v_document.status,
      'stockRequestLineCount',v_document.line_count,
      'stockRequestTotalBaseQty',v_document.requested_total_base_qty,
      'stockRequestCreated',FALSE
    );
  END IF;

  -- Serialize against incoming FIFO reconciliation before calculating the
  -- exact remaining shortage owned by this Session.
  PERFORM 1 FROM public.negative_stock_sale_allocations allocation
  JOIN public.sales_headers sale
    ON sale.company_id=allocation.company_id AND sale.id=allocation.sales_id
  WHERE allocation.company_id=p_company_id
    AND COALESCE(sale.posted_session_id,sale.session_id)=p_cashier_session_id
    AND allocation.reconciled_at IS NULL
    AND allocation.shortage_base_qty>allocation.replenished_base_qty
  ORDER BY allocation.created_at,allocation.id
  FOR UPDATE OF allocation;

  IF NOT EXISTS(SELECT 1
    FROM public.negative_stock_sale_allocations allocation
    JOIN public.sales_headers sale
      ON sale.company_id=allocation.company_id AND sale.id=allocation.sales_id
    WHERE allocation.company_id=p_company_id
      AND COALESCE(sale.posted_session_id,sale.session_id)=p_cashier_session_id
      AND allocation.reconciled_at IS NULL
      AND allocation.shortage_base_qty>allocation.replenished_base_qty
  ) THEN
    RETURN jsonb_build_object(
      'stockRequestId',NULL,'stockRequestNo',NULL,
      'stockRequestStatus',NULL,'stockRequestLineCount',0,
      'stockRequestTotalBaseQty',0,'stockRequestCreated',FALSE
    );
  END IF;

  v_request_no:='REQ-'||to_char(v_now,'YYYYMMDD')||'-'||
    lpad(nextval('private.stock_request_document_no_seq')::TEXT,10,'0');
  INSERT INTO public.stock_request_documents(
    company_id,request_no,store_id,requesting_pos_id,requesting_session_id,
    requested_by,needed_date,notes,status,request_source
  ) VALUES(
    p_company_id,v_request_no,v_session.store_id,v_session.pos_id,
    p_cashier_session_id,p_actor_id,CURRENT_DATE,
    'Otomatis dari stok minus sesi '||v_session.session_code,
    'DRAFT','NEGATIVE_STOCK_SESSION_CLOSE'
  ) RETURNING id INTO v_document_id;

  SELECT to_jsonb(document) INTO v_draft
  FROM public.stock_request_documents document
  WHERE document.company_id=p_company_id AND document.id=v_document_id;
  INSERT INTO public.stock_request_audit(
    company_id,document_id,action,actor_id,before_state,after_state
  ) VALUES(p_company_id,v_document_id,'CREATE',p_actor_id,NULL,v_draft);

  FOR v_product IN
    SELECT allocation.stock_product_id product_id,product.sku,product.name,
      product.uom_id,uom.name uom_name,
      sum(allocation.shortage_base_qty-allocation.replenished_base_qty)
        requested_base_qty
    FROM public.negative_stock_sale_allocations allocation
    JOIN public.sales_headers sale
      ON sale.company_id=allocation.company_id AND sale.id=allocation.sales_id
    JOIN public.products product
      ON product.company_id=allocation.company_id
     AND product.id=allocation.stock_product_id
    JOIN public.uoms uom
      ON uom.company_id=product.company_id AND uom.id=product.uom_id
    WHERE allocation.company_id=p_company_id
      AND COALESCE(sale.posted_session_id,sale.session_id)=p_cashier_session_id
      AND allocation.reconciled_at IS NULL
      AND allocation.shortage_base_qty>allocation.replenished_base_qty
    GROUP BY allocation.stock_product_id,product.sku,product.name,
      product.uom_id,uom.name
    ORDER BY product.name,allocation.stock_product_id
  LOOP
    v_line_no:=v_line_no+1;
    INSERT INTO public.stock_request_lines(
      company_id,document_id,line_no,client_line_key,product_id,
      requested_uom_id,requested_qty,factor_to_base_snapshot,
      requested_base_qty,product_sku_snapshot,product_name_snapshot,
      requested_uom_name_snapshot,notes
    ) VALUES(
      p_company_id,v_document_id,v_line_no,gen_random_uuid(),
      v_product.product_id,v_product.uom_id,v_product.requested_base_qty,1,
      v_product.requested_base_qty,v_product.sku,v_product.name,
      v_product.uom_name,'Kekurangan otomatis dari penjualan sesi kasir'
    ) RETURNING id INTO v_line_id;

    FOR v_allocation IN
      SELECT allocation.id,
        allocation.shortage_base_qty-allocation.replenished_base_qty
          outstanding_base_qty
      FROM public.negative_stock_sale_allocations allocation
      JOIN public.sales_headers sale
        ON sale.company_id=allocation.company_id AND sale.id=allocation.sales_id
      WHERE allocation.company_id=p_company_id
        AND COALESCE(sale.posted_session_id,sale.session_id)=p_cashier_session_id
        AND allocation.stock_product_id=v_product.product_id
        AND allocation.reconciled_at IS NULL
        AND allocation.shortage_base_qty>allocation.replenished_base_qty
      ORDER BY allocation.created_at,allocation.id
    LOOP
      INSERT INTO public.stock_request_negative_allocations(
        company_id,stock_request_document_id,stock_request_line_id,
        negative_stock_sale_allocation_id,requested_base_qty
      ) VALUES(
        p_company_id,v_document_id,v_line_id,v_allocation.id,
        v_allocation.outstanding_base_qty
      );
    END LOOP;
    v_line_count:=v_line_count+1;
    v_total:=v_total+v_product.requested_base_qty;
  END LOOP;

  UPDATE public.stock_request_documents SET
    status='SUBMITTED',line_count=v_line_count,
    requested_total_base_qty=v_total,submitted_by=p_actor_id,
    submitted_at=v_now,master_version=master_version+1,updated_at=v_now
  WHERE company_id=p_company_id AND id=v_document_id;
  SELECT to_jsonb(document) INTO v_submitted
  FROM public.stock_request_documents document
  WHERE document.company_id=p_company_id AND document.id=v_document_id;
  INSERT INTO public.stock_request_audit(
    company_id,document_id,action,actor_id,before_state,after_state
  ) VALUES(
    p_company_id,v_document_id,'SUBMIT',p_actor_id,v_draft,v_submitted
  );

  RETURN jsonb_build_object(
    'stockRequestId',v_document_id,'stockRequestNo',v_request_no,
    'stockRequestStatus','SUBMITTED','stockRequestLineCount',v_line_count,
    'stockRequestTotalBaseQty',v_total,'stockRequestCreated',TRUE
  );
END
$$;

ALTER FUNCTION public.close_cashier_session(UUID,BIGINT,NUMERIC)
  RENAME TO prd_close_cashier_session_core;
ALTER FUNCTION public.prd_close_cashier_session_core(UUID,BIGINT,NUMERIC)
  SET SCHEMA private;

CREATE FUNCTION public.close_cashier_session(
  p_cashier_session_id UUID,p_master_version BIGINT,
  p_closing_cash_actual NUMERIC
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
  v_actor UUID:=auth.uid();v_result JSONB;v_request JSONB;
BEGIN
  v_result:=private.prd_close_cashier_session_core(
    p_cashier_session_id,p_master_version,p_closing_cash_actual);
  v_request:=private.ensure_negative_session_stock_request(
    v_company,p_cashier_session_id,v_actor);
  RETURN v_result||v_request;
END
$$;

CREATE FUNCTION public.get_pos_negative_stock_readiness()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_session public.cashier_sessions%ROWTYPE;v_feature BOOLEAN:=FALSE;
  v_policy public.pos_negative_stock_policies%ROWTYPE;
  v_permission public.pos_negative_stock_permissions%ROWTYPE;
  v_warehouse_opt_in BOOLEAN:=FALSE;v_blocker TEXT;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT * INTO v_session FROM public.cashier_sessions session
  WHERE session.company_id=v_company AND session.cashier_id=v_actor
    AND session.status='OPEN'::public.session_status;
  IF NOT FOUND THEN RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED'; END IF;
  SELECT COALESCE(feature.is_enabled,FALSE) INTO v_feature
  FROM (SELECT 1) seed LEFT JOIN public.company_features feature
    ON feature.company_id=v_company
   AND feature.feature_code='pos_negative_stock_enabled';
  SELECT * INTO v_policy FROM public.pos_negative_stock_policies policy
  WHERE policy.company_id=v_company;
  SELECT warehouse.allow_negative_stock INTO v_warehouse_opt_in
  FROM public.warehouses warehouse
  WHERE warehouse.company_id=v_company AND warehouse.id=v_session.sales_warehouse_id
    AND warehouse.is_active AND warehouse.is_sale_source;
  SELECT * INTO v_permission FROM public.pos_negative_stock_permissions permission
  WHERE permission.company_id=v_company
    AND permission.warehouse_id=v_session.sales_warehouse_id
    AND permission.user_id=v_actor AND permission.is_active
    AND (permission.valid_until IS NULL OR permission.valid_until>clock_timestamp());
  v_blocker:=CASE
    WHEN NOT v_feature THEN 'NEGATIVE_STOCK_FEATURE_DISABLED'
    WHEN v_policy.id IS NULL OR NOT v_policy.is_active
      THEN 'NEGATIVE_STOCK_POLICY_INACTIVE'
    WHEN NOT COALESCE(v_warehouse_opt_in,FALSE)
      THEN 'NEGATIVE_STOCK_WAREHOUSE_NOT_OPTED_IN'
    WHEN v_permission.id IS NULL
      THEN 'NEGATIVE_STOCK_USER_PERMISSION_REQUIRED'
    ELSE NULL END;
  RETURN jsonb_build_object(
    'enabled',v_blocker IS NULL,'blockerCode',v_blocker,
    'onlineOnly',TRUE,'bundleSupported',FALSE,
    'requireReason',COALESCE(v_policy.require_reason,TRUE),
    'companyLimitBaseQty',v_policy.company_negative_limit_base_qty,
    'userLimitBaseQty',v_permission.max_negative_base_qty,
    'warehouseId',v_session.sales_warehouse_id,
    'permissionValidUntil',v_permission.valid_until
  );
END
$$;

CREATE OR REPLACE FUNCTION public.get_purchase_supplier_orders()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','VIEW');
  RETURN jsonb_build_object(
    'companyId',v_company,
    'requests',(SELECT COALESCE(jsonb_agg(to_jsonb(request_row)
      ORDER BY request_row.requested_at DESC,request_row.id),'[]'::JSONB)
      FROM (SELECT document.id,document.request_no,document.store_id,
          document.request_source,document.needed_date,document.notes,
          document.status,document.line_count,
          document.requested_total_base_qty,document.master_version,
          document.requested_at
        FROM public.stock_request_documents document
        WHERE document.company_id=v_company
          AND document.status IN('SUBMITTED','ORDERED')
        ORDER BY document.requested_at DESC,document.id LIMIT 500) request_row),
    'requestLines',(SELECT COALESCE(jsonb_agg(to_jsonb(line_row)
      ORDER BY line_row.document_id,line_row.line_no),'[]'::JSONB)
      FROM (SELECT line.id,line.document_id,line.line_no,line.product_id,
          line.requested_uom_id,line.requested_qty,
          line.factor_to_base_snapshot,line.requested_base_qty,
          line.product_sku_snapshot,line.product_name_snapshot,
          line.requested_uom_name_snapshot,line.notes
        FROM public.stock_request_lines line
        JOIN public.stock_request_documents document
          ON document.company_id=line.company_id AND document.id=line.document_id
        WHERE line.company_id=v_company
          AND document.status IN('SUBMITTED','ORDERED')
        ORDER BY line.document_id,line.line_no LIMIT 10000) line_row),
    'orders',(SELECT COALESCE(jsonb_agg(to_jsonb(order_row)
      ORDER BY order_row.created_at DESC,order_row.id),'[]'::JSONB)
      FROM (SELECT document.id,document.order_no,document.store_id,
          document.destination_warehouse_id,document.supplier_id,
          document.order_date,document.expected_date,document.status,
          document.notes,document.line_count,document.total_ordered_base_qty,
          document.estimated_total,document.master_version,document.created_at
        FROM public.supplier_order_documents document
        WHERE document.company_id=v_company
        ORDER BY document.created_at DESC,document.id LIMIT 500) order_row),
    'orderLines',(SELECT COALESCE(jsonb_agg(to_jsonb(line_row)
      ORDER BY line_row.document_id,line_row.line_no),'[]'::JSONB)
      FROM (SELECT line.id,line.document_id,line.line_no,line.product_id,
          line.ordered_uom_id,line.ordered_qty,line.ordered_base_qty,
          line.estimated_unit_price,line.estimated_subtotal,
          line.product_name_snapshot,line.ordered_uom_name_snapshot
        FROM public.supplier_order_lines line
        WHERE line.company_id=v_company
        ORDER BY line.document_id,line.line_no LIMIT 10000) line_row),
    'allocations',(SELECT COALESCE(jsonb_agg(to_jsonb(allocation_row)
      ORDER BY allocation_row.id),'[]'::JSONB)
      FROM (SELECT allocation.id,allocation.supplier_order_line_id,
          allocation.stock_request_line_id,allocation.allocated_base_qty
        FROM public.supplier_order_request_allocations allocation
        WHERE allocation.company_id=v_company LIMIT 20000) allocation_row),
    'suppliers',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',supplier.id,'supplier_name',supplier.supplier_name)
      ORDER BY supplier.supplier_name,supplier.id),'[]'::JSONB)
      FROM public.suppliers supplier WHERE supplier.company_id=v_company
        AND supplier.is_active),
    'productSuppliers',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'product_id',relation.product_id,'supplier_id',relation.supplier_id,
      'purchase_uom_id',relation.purchase_uom_id,
      'reference_purchase_price',relation.reference_purchase_price,
      'last_purchase_price',relation.last_purchase_price,
      'is_preferred_supplier',relation.is_preferred_supplier,
      'is_active',relation.is_active)),'[]'::JSONB)
      FROM public.product_suppliers relation
      WHERE relation.company_id=v_company AND relation.is_active),
    'warehouses',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',warehouse.id,'name',warehouse.name,'store_id',warehouse.store_id)
      ORDER BY warehouse.name,warehouse.id),'[]'::JSONB)
      FROM public.warehouses warehouse WHERE warehouse.company_id=v_company
        AND warehouse.is_active AND warehouse.is_purchase_destination),
    'stores',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',store.id,'store_name',store.store_name)
      ORDER BY store.store_name,store.id),'[]'::JSONB)
      FROM public.stores store WHERE store.company_id=v_company
        AND store.status='ACTIVE'),
    'purchaseUoms',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'product_id',product_uom.product_id,'uom_id',product_uom.uom_id,
      'purchase_price',product_uom.purchase_price)),'[]'::JSONB)
      FROM public.product_uoms product_uom
      WHERE product_uom.company_id=v_company AND product_uom.is_active
        AND product_uom.purchase_allowed));
END
$$;

ALTER TABLE public.stock_request_negative_allocations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.stock_request_negative_allocations FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.stock_request_negative_allocations TO service_role;
REVOKE ALL ON FUNCTION
  private.trg_prd_guard_negative_stock_request_lineage(),
  private.trg_prd_guard_automatic_stock_request(),
  private.ensure_negative_session_stock_request(UUID,UUID,UUID),
  private.prd_close_cashier_session_core(UUID,BIGINT,NUMERIC)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.trg_prd_guard_negative_stock_request_lineage(),
  private.trg_prd_guard_automatic_stock_request(),
  private.ensure_negative_session_stock_request(UUID,UUID,UUID),
  private.prd_close_cashier_session_core(UUID,BIGINT,NUMERIC)
TO service_role;
REVOKE ALL ON FUNCTION public.close_cashier_session(UUID,BIGINT,NUMERIC),
  public.get_pos_negative_stock_readiness() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.close_cashier_session(UUID,BIGINT,NUMERIC),
  public.get_pos_negative_stock_readiness() TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260819170000','negative_stock_session_replenishment_request',
  'Creates one audited submitted Stock Request per closed Cashier Session from exact unreconciled authorized online negative-stock allocations');
NOTIFY pgrst,'reload schema';
COMMIT;
