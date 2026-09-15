-- Additive read-only compatibility. No transaction backfill or writer changes.
BEGIN;
DO $guard$ BEGIN
 IF to_regprocedure('public.get_backoffice_sales_orders_v3(text,text,text,text,date,date,text,integer)') IS NULL
 OR to_regclass('public.sales_process_cutover_audit') IS NULL
 OR to_regprocedure('public.get_office_retail_history(uuid)') IS NOT NULL
 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Office history reader dependencies/collision'; END IF;
END $guard$;
CREATE FUNCTION public.get_office_retail_history(p_sales_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_company uuid:=public.private_active_company_id(); v_rows jsonb;
BEGIN
 PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','VIEW');
 SELECT COALESCE(jsonb_agg(jsonb_build_object(
  'id',sale.id,'companyId',sale.company_id,'documentNo',COALESCE(sale.draft_no,sale.invoice_no),
  'invoiceNo',invoice.invoice_no,'invoiceSnapshotId',invoice.id,
  'status',sale.order_runtime_status,'documentStatus',sale.document_status,
  'masterVersion',sale.master_version,'fulfillmentMode',sale.fulfillment_mode,
  'sourceChannel',sale.source_channel,'createdAt',sale.created_at,
  'snapshotProvenance',invoice.snapshot_provenance,
  'kind',CASE WHEN sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED') THEN 'QUOTATION' ELSE 'SALES_ORDER' END,
  'orderDate',COALESCE(sale.planned_order_date,(sale.transaction_date AT TIME ZONE company.timezone)::date),
  'deliveryDate',(sale.delivery_scheduled_at AT TIME ZONE company.timezone)::date,
  'dueDate',(sale.due_date AT TIME ZONE company.timezone)::date,
  'customerName',customer.name,'storeName',store.store_name,
  'total',sale.grand_total_after_rounding,'notes',COALESCE(sale.draft_notes,sale.delivery_notes),
  'targetId',lineage.target_id,'targetNo',lineage.target_no,
  'lines',CASE WHEN p_sales_id IS NULL THEN '[]'::jsonb ELSE
    COALESCE((SELECT jsonb_agg(jsonb_build_object('id',detail.id,
      'productName',product.name,'quantity',detail.qty,'unitPrice',detail.price,
      'total',detail.subtotal) ORDER BY detail.id)
      FROM public.sales_details detail LEFT JOIN public.products product
      ON product.company_id=detail.company_id AND product.id=detail.product_id
      WHERE detail.company_id=v_company AND detail.sales_id=sale.id),'[]'::jsonb) END
 ) ORDER BY sale.transaction_date DESC,sale.id),'[]'::jsonb) INTO v_rows
 FROM public.sales_headers sale
 JOIN public.companies company ON company.id=sale.company_id
 LEFT JOIN public.customers customer ON customer.company_id=sale.company_id AND customer.id=sale.customer_id
 LEFT JOIN public.stores store ON store.company_id=sale.company_id AND store.id=sale.store_id
 LEFT JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
 LEFT JOIN LATERAL (
  SELECT (audit.after_state->'converterResult'->>'targetDocumentId')::uuid target_id,
   audit.after_state->'converterResult'->>'targetDocumentNo' target_no
  FROM public.sales_process_cutover_items item JOIN public.sales_process_cutover_audit audit
  ON audit.company_id=item.company_id AND audit.cutover_item_id=item.id
  WHERE item.company_id=sale.company_id AND item.source_document_id=sale.id
  AND item.source_document_type='RETAIL_SALE' AND audit.action='APPLY_ITEM'
  AND audit.after_state->'converterResult'->>'targetDocumentType'='BACKOFFICE_SALES_ORDER'
  ORDER BY audit.created_at DESC,audit.id DESC LIMIT 1
 ) lineage ON true
 WHERE sale.company_id=v_company AND (p_sales_id IS NULL OR sale.id=p_sales_id)
 AND (p_sales_id IS NOT NULL OR lineage.target_id IS NULL);
 IF p_sales_id IS NOT NULL AND jsonb_array_length(v_rows)=0 THEN
  RAISE EXCEPTION 'SALES_DOCUMENT_NOT_FOUND'; END IF;
 RETURN jsonb_build_object('companyId',v_company,'data',v_rows);
END $$;
REVOKE ALL ON FUNCTION public.get_office_retail_history(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_office_retail_history(uuid) TO authenticated,service_role;
INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260916110000','office_retail_history_reader','Read-only compatibility; no transaction backfill/writer changes.');
NOTIFY pgrst,'reload schema';
COMMIT;
