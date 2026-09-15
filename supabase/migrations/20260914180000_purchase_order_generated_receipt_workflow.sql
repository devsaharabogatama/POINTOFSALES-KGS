-- Purchase workflow correction: PO creation owns Receipt-document creation.
-- Warehouse fills the generated document; PO never starts Receipt interactively.
BEGIN;

DO $guard$
DECLARE v_missing text[];v_definition text;
BEGIN
  SELECT array_agg(required_version) INTO v_missing FROM (VALUES
    ('20260913120000'),('20260913130000'),('20260914100000'),
    ('20260914140000'),('20260914150000'),('20260914160000'),('20260914170000')
  ) dependency(required_version)
  WHERE NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations migration
    WHERE migration.version=dependency.required_version);
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: missing %',v_missing;
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914180000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260914180000';
  END IF;
  IF to_regprocedure('private.sync_purchase_order_receipt_documents(uuid,uuid,uuid,timestamptz)') IS NOT NULL
    OR to_regprocedure('public.save_generated_backoffice_goods_receipt(uuid,bigint,uuid,text,text,jsonb)') IS NOT NULL
    OR to_regprocedure('public.post_generated_backoffice_goods_receipt(uuid,bigint,uuid)') IS NOT NULL
    OR to_regprocedure('private.trg_sync_purchase_order_receipt_documents()') IS NOT NULL
    OR to_regclass('public.purchase_order_active_receipt_warehouse_uidx') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: generated Receipt workflow collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs run
      WHERE run.status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue exists';
  END IF;
  IF EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
      WHERE receipt.source_channel='BACKOFFICE' AND receipt.status='DRAFT'
      GROUP BY receipt.company_id,receipt.supplier_order_id,receipt.warehouse_id
      HAVING count(*)>1) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: duplicate active Receipt Draft per PO/Warehouse';
  END IF;
  SELECT pg_get_functiondef(
    'private.revise_purchase_supplier_order_core(uuid,uuid,bigint,uuid,uuid,date,text,jsonb)'::regprocedure)
  INTO v_definition;
  IF v_definition !~ 'receipt.status\s*<>\s*''CANCELED''' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: PO revision Receipt boundary drift';
  END IF;
END
$guard$;

CREATE UNIQUE INDEX purchase_order_active_receipt_warehouse_uidx
ON public.goods_receipt_documents(company_id,supplier_order_id,warehouse_id)
WHERE source_channel='BACKOFFICE' AND status='DRAFT';

CREATE FUNCTION private.sync_purchase_order_receipt_documents(
  p_company_id uuid,p_supplier_order_id uuid,p_actor_id uuid,p_effective_at timestamptz
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_order public.supplier_order_documents%rowtype;v_receipt record;
  v_destination record;v_receipt_id uuid;v_receipt_no text;v_created integer:=0;
  v_canceled integer:=0;v_now timestamptz:=COALESCE(p_effective_at,clock_timestamp());
  v_before jsonb;
BEGIN
  IF p_company_id IS NULL OR p_supplier_order_id IS NULL OR p_actor_id IS NULL THEN
    RAISE EXCEPTION 'PURCHASE_RECEIPT_SYNC_CONTEXT_REQUIRED'; END IF;
  SELECT * INTO v_order FROM public.supplier_order_documents source
  WHERE source.company_id=p_company_id AND source.id=p_supplier_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SUPPLIER_ORDER_NOT_FOUND'; END IF;

  -- Cancel only untouched generated Drafts which are no longer applicable.
  FOR v_receipt IN SELECT receipt.* FROM public.goods_receipt_documents receipt
    WHERE receipt.company_id=p_company_id AND receipt.supplier_order_id=p_supplier_order_id
      AND receipt.source_channel='BACKOFFICE' AND receipt.status='DRAFT'
      AND receipt.line_count=0
      AND NOT EXISTS(SELECT 1 FROM public.goods_receipt_lines line
        WHERE line.company_id=receipt.company_id AND line.document_id=receipt.id)
      AND (v_order.status='CANCELED' OR NOT EXISTS(
        SELECT 1 FROM public.supplier_order_lines order_line
        WHERE order_line.company_id=p_company_id
          AND order_line.document_id=p_supplier_order_id
          AND order_line.destination_warehouse_id=receipt.warehouse_id
          AND order_line.ordered_base_qty>COALESCE((SELECT sum(receipt_line.received_base_qty)
            FROM public.goods_receipt_lines receipt_line
            JOIN public.goods_receipt_documents posted
              ON posted.company_id=receipt_line.company_id
             AND posted.id=receipt_line.document_id AND posted.status='POSTED'
            WHERE receipt_line.company_id=p_company_id
              AND receipt_line.supplier_order_line_id=order_line.id),0)))
    FOR UPDATE
  LOOP
    v_before:=to_jsonb(v_receipt);
    UPDATE public.goods_receipt_documents SET status='CANCELED',canceled_by=p_actor_id,
      canceled_at=v_now,master_version=master_version+1,updated_at=v_now
    WHERE company_id=p_company_id AND id=v_receipt.id;
    INSERT INTO public.goods_receipt_audit(company_id,document_id,action,actor_id,
      before_state,after_state)
    SELECT p_company_id,v_receipt.id,'CANCEL',p_actor_id,v_before,to_jsonb(receipt)
    FROM public.goods_receipt_documents receipt
    WHERE receipt.company_id=p_company_id AND receipt.id=v_receipt.id;
    v_canceled:=v_canceled+1;
  END LOOP;

  IF v_order.status NOT IN('CONFIRMED','PARTIALLY_RECEIVED') THEN
    RETURN jsonb_build_object('supplierOrderId',p_supplier_order_id,
      'createdReceiptCount',0,'canceledReceiptCount',v_canceled);
  END IF;

  FOR v_destination IN
    SELECT order_line.destination_warehouse_id warehouse_id,warehouse.store_id
    FROM public.supplier_order_lines order_line
    JOIN public.warehouses warehouse ON warehouse.company_id=order_line.company_id
      AND warehouse.id=order_line.destination_warehouse_id
      AND warehouse.is_active AND warehouse.is_purchase_destination
      AND warehouse.warehouse_type IS DISTINCT FROM 'TRANSIT'
    WHERE order_line.company_id=p_company_id
      AND order_line.document_id=p_supplier_order_id
      AND order_line.destination_warehouse_id IS NOT NULL
      AND order_line.ordered_base_qty>COALESCE((SELECT sum(receipt_line.received_base_qty)
        FROM public.goods_receipt_lines receipt_line
        JOIN public.goods_receipt_documents posted
          ON posted.company_id=receipt_line.company_id
         AND posted.id=receipt_line.document_id AND posted.status='POSTED'
        WHERE receipt_line.company_id=p_company_id
          AND receipt_line.supplier_order_line_id=order_line.id),0)
    GROUP BY order_line.destination_warehouse_id,warehouse.store_id
    ORDER BY order_line.destination_warehouse_id
  LOOP
    IF NOT EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
        WHERE receipt.company_id=p_company_id
          AND receipt.supplier_order_id=p_supplier_order_id
          AND receipt.warehouse_id=v_destination.warehouse_id
          AND receipt.source_channel='BACKOFFICE' AND receipt.status='DRAFT') THEN
      v_receipt_no:='GR-'||to_char(v_order.order_date,'YYYYMMDD')||'-'||
        lpad(nextval('private.goods_receipt_no_seq')::text,10,'0');
      INSERT INTO public.goods_receipt_documents(company_id,receipt_no,
        supplier_order_id,store_id,warehouse_id,receiving_session_id,
        receiving_pos_id,received_by,received_at,source_channel,receipt_scope,
        purchase_daily_batch_id,supplier_id_snapshot,supplier_assignment_status,
        unassigned_clearing_status)
      VALUES(p_company_id,v_receipt_no,p_supplier_order_id,
        COALESCE(v_order.store_id,v_destination.store_id),v_destination.warehouse_id,
        NULL,NULL,p_actor_id,v_now,'BACKOFFICE',
        CASE WHEN v_order.document_scope='COMPANY_MULTI_WAREHOUSE'
          THEN 'DAILY_WAREHOUSE' ELSE 'STORE' END,
        CASE WHEN v_order.document_scope='COMPANY_MULTI_WAREHOUSE'
          THEN v_order.purchase_daily_batch_id ELSE NULL END,
        v_order.supplier_id,
        CASE WHEN v_order.document_scope='COMPANY_MULTI_WAREHOUSE'
            AND v_order.supplier_id IS NULL THEN 'SUPPLIER_PENDING' ELSE 'ASSIGNED' END,
        CASE WHEN v_order.document_scope='COMPANY_MULTI_WAREHOUSE'
            AND v_order.supplier_id IS NULL THEN 'OPEN' ELSE 'NOT_APPLICABLE' END)
      RETURNING id,receipt_no INTO v_receipt_id,v_receipt_no;
      INSERT INTO public.goods_receipt_audit(company_id,document_id,action,actor_id,
        before_state,after_state)
      SELECT p_company_id,v_receipt_id,'CREATE',p_actor_id,NULL,to_jsonb(receipt)
      FROM public.goods_receipt_documents receipt
      WHERE receipt.company_id=p_company_id AND receipt.id=v_receipt_id;
      v_created:=v_created+1;
    ELSE
      UPDATE public.goods_receipt_documents receipt SET
        supplier_id_snapshot=v_order.supplier_id,
        supplier_assignment_status=CASE WHEN receipt.receipt_scope='DAILY_WAREHOUSE'
            AND v_order.supplier_id IS NULL THEN 'SUPPLIER_PENDING' ELSE 'ASSIGNED' END,
        unassigned_clearing_status=CASE WHEN receipt.receipt_scope='DAILY_WAREHOUSE'
            AND v_order.supplier_id IS NULL THEN 'OPEN' ELSE 'NOT_APPLICABLE' END,
        updated_at=v_now
      WHERE receipt.company_id=p_company_id
        AND receipt.supplier_order_id=p_supplier_order_id
        AND receipt.warehouse_id=v_destination.warehouse_id
        AND receipt.source_channel='BACKOFFICE' AND receipt.status='DRAFT'
        AND receipt.line_count=0
        AND NOT EXISTS(SELECT 1 FROM public.goods_receipt_lines line
          WHERE line.company_id=receipt.company_id AND line.document_id=receipt.id);
    END IF;
  END LOOP;
  RETURN jsonb_build_object('supplierOrderId',p_supplier_order_id,
    'createdReceiptCount',v_created,'canceledReceiptCount',v_canceled);
END
$$;

CREATE FUNCTION private.trg_sync_purchase_order_receipt_documents()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_actor uuid:=COALESCE(auth.uid(),NEW.confirmed_by,NEW.ordered_by);
BEGIN
  IF NEW.status IN('CONFIRMED','PARTIALLY_RECEIVED','CANCELED') THEN
    PERFORM private.sync_purchase_order_receipt_documents(
      NEW.company_id,NEW.id,v_actor,clock_timestamp());
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER sync_purchase_order_receipt_documents
AFTER UPDATE OF status, supplier_id, expected_date, total_ordered_base_qty
ON public.supplier_order_documents FOR EACH ROW
EXECUTE FUNCTION private.trg_sync_purchase_order_receipt_documents();

-- Empty generated Receipt Drafts are workflow placeholders, not a started Receipt.
DO $patch_revision$
DECLARE v_definition text;v_patched text;
BEGIN
  SELECT pg_get_functiondef(
    'private.revise_purchase_supplier_order_core(uuid,uuid,bigint,uuid,uuid,date,text,jsonb)'::regprocedure)
  INTO v_definition;
  v_patched:=regexp_replace(v_definition,
    'AND receipt\.status\s*<>\s*''CANCELED''',
    'AND receipt.status<>''CANCELED'' AND (receipt.status=''POSTED'' OR receipt.line_count>0 OR EXISTS(SELECT 1 FROM public.goods_receipt_lines started_line WHERE started_line.company_id=receipt.company_id AND started_line.document_id=receipt.id))');
  IF v_patched=v_definition THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: PO revision patch anchor missing';
  END IF;
  EXECUTE v_patched;
END
$patch_revision$;

CREATE FUNCTION public.save_generated_backoffice_goods_receipt(
  p_document_id uuid,p_master_version bigint,p_supplier_order_id uuid,
  p_supplier_delivery_no text,p_notes text,p_lines jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_actor uuid:=auth.uid();v_company uuid:=public.private_active_company_id();
  v_receipt public.goods_receipt_documents%rowtype;v_before jsonb;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_document_id IS NULL THEN RAISE EXCEPTION 'GENERATED_GOODS_RECEIPT_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.goods_receipts','EDIT_DRAFT');
  SELECT * INTO v_receipt FROM public.goods_receipt_documents receipt
  WHERE receipt.company_id=v_company AND receipt.id=p_document_id FOR UPDATE;
  IF NOT FOUND OR v_receipt.source_channel<>'BACKOFFICE'
    OR v_receipt.status<>'DRAFT' OR v_receipt.supplier_order_id<>p_supplier_order_id THEN
    RAISE EXCEPTION 'GENERATED_GOODS_RECEIPT_NOT_FOUND'; END IF;
  IF p_master_version IS DISTINCT FROM v_receipt.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF v_receipt.received_by<>v_actor THEN
    IF v_receipt.line_count<>0 OR EXISTS(SELECT 1 FROM public.goods_receipt_lines line
        WHERE line.company_id=v_company AND line.document_id=v_receipt.id) THEN
      RAISE EXCEPTION 'GOODS_RECEIPT_OWNER_SCOPE_INVALID'; END IF;
    v_before:=to_jsonb(v_receipt);
    UPDATE public.goods_receipt_documents SET received_by=v_actor,
      master_version=master_version+1,updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=v_receipt.id
    RETURNING * INTO v_receipt;
    INSERT INTO public.goods_receipt_audit(company_id,document_id,action,actor_id,
      before_state,after_state)
    VALUES(v_company,v_receipt.id,'UPDATE',v_actor,v_before,to_jsonb(v_receipt));
  END IF;
  IF v_receipt.receipt_scope='DAILY_WAREHOUSE' THEN
    RETURN public.save_purchase_daily_goods_receipt(v_receipt.id,
      v_receipt.master_version,p_supplier_order_id,v_receipt.warehouse_id,
      p_supplier_delivery_no,p_notes,p_lines);
  END IF;
  RETURN public.save_backoffice_goods_receipt(v_receipt.id,
    v_receipt.master_version,p_supplier_order_id,p_supplier_delivery_no,p_notes,p_lines);
END
$$;

CREATE FUNCTION public.post_generated_backoffice_goods_receipt(
  p_document_id uuid,p_master_version bigint,p_idempotency_key uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_receipt record;
BEGIN
  SELECT receipt.receipt_scope INTO v_receipt
  FROM public.goods_receipt_documents receipt
  WHERE receipt.company_id=v_company AND receipt.id=p_document_id
    AND receipt.source_channel='BACKOFFICE';
  IF NOT FOUND THEN RAISE EXCEPTION 'GENERATED_GOODS_RECEIPT_NOT_FOUND'; END IF;
  IF v_receipt.receipt_scope='DAILY_WAREHOUSE' THEN
    RETURN public.post_purchase_daily_goods_receipt(
      p_document_id,p_master_version,p_idempotency_key);
  END IF;
  RETURN public.post_backoffice_goods_receipt(
    p_document_id,p_master_version,p_idempotency_key);
END
$$;

CREATE OR REPLACE FUNCTION public.get_backoffice_goods_receipt_workspace()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.goods_receipts','VIEW');
  RETURN jsonb_build_object('goodsReceiptWorkspaceVersion',2,
    'orders',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.expected_date NULLS LAST,row_data.order_no),'[]'::jsonb)
      FROM (SELECT document.id,document.order_no,document.store_id,
          document.supplier_id,COALESCE(supplier.supplier_name,'Supplier belum ditentukan') supplier_name,
          document.status,document.expected_date
        FROM public.supplier_order_documents document
        LEFT JOIN public.suppliers supplier ON supplier.company_id=document.company_id
          AND supplier.id=document.supplier_id
        WHERE document.company_id=v_company
          AND document.status IN('CONFIRMED','PARTIALLY_RECEIVED')
          AND EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
            WHERE receipt.company_id=document.company_id
              AND receipt.supplier_order_id=document.id
              AND receipt.source_channel='BACKOFFICE' AND receipt.status='DRAFT')) row_data),
    'orderLines',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.document_id,row_data.line_no),'[]'::jsonb)
      FROM (SELECT line.id,line.document_id,line.line_no,line.product_id,
          line.ordered_uom_id,line.ordered_qty,line.ordered_base_qty,
          line.product_name_snapshot,line.ordered_uom_name_snapshot,
          line.destination_warehouse_id,
          greatest(line.ordered_base_qty-COALESCE((SELECT sum(receipt_line.received_base_qty)
            FROM public.goods_receipt_lines receipt_line
            JOIN public.goods_receipt_documents receipt
              ON receipt.company_id=receipt_line.company_id
             AND receipt.id=receipt_line.document_id AND receipt.status='POSTED'
            WHERE receipt_line.company_id=v_company
              AND receipt_line.supplier_order_line_id=line.id),0),0) remaining_base_qty
        FROM public.supplier_order_lines line
        JOIN public.supplier_order_documents document
          ON document.company_id=line.company_id AND document.id=line.document_id
        WHERE line.company_id=v_company
          AND document.status IN('CONFIRMED','PARTIALLY_RECEIVED')) row_data),
    'productUoms',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'product_id',product_uom.product_id,'uom_id',product_uom.uom_id,
        'factor_to_base',product_uom.factor_to_base,'uom_name',uom.name,
        'allow_decimal',uom.allow_decimal,'decimal_precision',uom.decimal_precision)
      ORDER BY product_uom.product_id,product_uom.factor_to_base DESC,uom.name),'[]'::jsonb)
      FROM public.product_uoms product_uom
      JOIN public.uoms uom ON uom.company_id=product_uom.company_id
        AND uom.id=product_uom.uom_id
      WHERE product_uom.company_id=v_company AND product_uom.is_active
        AND product_uom.purchase_allowed AND uom.is_active),
    'drafts',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.received_at,row_data.receipt_no),'[]'::jsonb)
      FROM (SELECT receipt.id,receipt.receipt_no,receipt.supplier_order_id,
          receipt.supplier_delivery_no,receipt.notes,receipt.master_version,
          receipt.received_at,receipt.received_by,receipt.warehouse_id,
          warehouse.name warehouse_name,receipt.line_count
        FROM public.goods_receipt_documents receipt
        JOIN public.warehouses warehouse ON warehouse.company_id=receipt.company_id
          AND warehouse.id=receipt.warehouse_id
        WHERE receipt.company_id=v_company AND receipt.status='DRAFT'
          AND receipt.source_channel='BACKOFFICE') row_data),
    'draftLines',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.document_id,row_data.line_no),'[]'::jsonb)
      FROM (SELECT line.document_id,line.line_no,line.client_line_key,
          line.supplier_order_line_id,line.received_uom_id,line.received_qty,
          line.accepted_good_qty,line.damaged_qty,line.rejected_qty
        FROM public.goods_receipt_lines line
        JOIN public.goods_receipt_documents receipt
          ON receipt.company_id=line.company_id AND receipt.id=line.document_id
        WHERE line.company_id=v_company AND receipt.status='DRAFT'
          AND receipt.source_channel='BACKOFFICE') row_data));
END
$$;

-- Install generated Receipt Drafts for open historical PO rows without changing
-- any final Receipt, Stock, FIFO, AP, Bill, Payment, or Journal row.
DO $backfill$
DECLARE v_order record;v_actor uuid;
BEGIN
  FOR v_order IN SELECT document.company_id,document.id,
      COALESCE(document.confirmed_by,document.ordered_by) actor_id,
      COALESCE(document.confirmed_at,document.updated_at,document.created_at) effective_at
    FROM public.supplier_order_documents document
    WHERE document.status IN('CONFIRMED','PARTIALLY_RECEIVED')
    ORDER BY document.company_id,document.id
  LOOP
    v_actor:=v_order.actor_id;
    IF v_actor IS NOT NULL THEN
      PERFORM private.sync_purchase_order_receipt_documents(
        v_order.company_id,v_order.id,v_actor,v_order.effective_at);
    END IF;
  END LOOP;
END
$backfill$;

REVOKE ALL ON FUNCTION
  private.sync_purchase_order_receipt_documents(uuid,uuid,uuid,timestamptz),
  private.trg_sync_purchase_order_receipt_documents()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.sync_purchase_order_receipt_documents(uuid,uuid,uuid,timestamptz),
  private.trg_sync_purchase_order_receipt_documents()
TO service_role;
REVOKE ALL ON FUNCTION
  public.save_generated_backoffice_goods_receipt(uuid,bigint,uuid,text,text,jsonb),
  public.post_generated_backoffice_goods_receipt(uuid,bigint,uuid),
  public.get_backoffice_goods_receipt_workspace()
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.save_generated_backoffice_goods_receipt(uuid,bigint,uuid,text,text,jsonb),
  public.post_generated_backoffice_goods_receipt(uuid,bigint,uuid),
  public.get_backoffice_goods_receipt_workspace()
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260914180000','purchase_order_generated_receipt_workflow',
  'PO creation generates per-Warehouse Receipt Drafts; Warehouse fills generated documents; partial receipt regenerates remaining Draft; Bill remains gated by Posted received quantity');
NOTIFY pgrst,'reload schema';
COMMIT;
