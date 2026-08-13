-- ACP-6E: enforce Supplier Invoice capabilities without releasing Finance
-- HOLD events, exposing dedicated tables, or granting Supplier Payment the
-- Supplier Invoice management authority.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813100000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-6D compatibility required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
    WHERE permission_key='finance.supplier_invoices'
      AND enforcement_status='SHADOW')<>1 THEN
    RAISE EXCEPTION 'SUPPLIER_INVOICE_PERMISSION_NOT_SHADOW';
  END IF;
  IF EXISTS(SELECT 1 FROM public.supplier_invoice_documents document
    LEFT JOIN public.financial_events event
      ON event.company_id=document.company_id
     AND event.id=document.financial_event_id
    WHERE document.status='VALIDATED' AND (
      event.id IS NULL OR event.source_table<>'supplier_invoice_documents'
      OR event.source_id<>document.id
      OR event.event_type<>'SUPPLIER_INVOICE_VALIDATED'::public.event_type)) THEN
    RAISE EXCEPTION 'SUPPLIER_INVOICE_EVENT_HISTORY_NOT_RECONCILED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.financial_events event
    WHERE event.source_table='supplier_invoice_documents'
      AND event.status<>'HOLD') THEN
    RAISE EXCEPTION 'SUPPLIER_INVOICE_FINANCE_EVENT_NOT_HOLD';
  END IF;
END
$guard$;

CREATE FUNCTION public.get_finance_supplier_invoices()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
  v_permission JSONB;
BEGIN
  v_permission:=private.acp_require_permission_capability(
    v_company,'finance.supplier_invoices','VIEW');
  RETURN jsonb_build_object(
    'companyId',v_company,'currentUserId',auth.uid(),
    'effectiveCapabilities',COALESCE(
      v_permission->'effectiveCapabilities','[]'::JSONB),
    'data',(SELECT COALESCE(jsonb_agg(to_jsonb(document)
      ORDER BY document.created_at DESC,document.id DESC),'[]'::JSONB)
      FROM (SELECT candidate.* FROM public.supplier_invoice_documents candidate
        WHERE candidate.company_id=v_company
        ORDER BY candidate.created_at DESC,candidate.id DESC LIMIT 500) document),
    'lines',(SELECT COALESCE(jsonb_agg(to_jsonb(line)
      ORDER BY line.document_id,line.line_no),'[]'::JSONB)
      FROM public.supplier_invoice_lines line WHERE line.company_id=v_company
        AND EXISTS(SELECT 1 FROM (SELECT candidate.id
          FROM public.supplier_invoice_documents candidate
          WHERE candidate.company_id=v_company
          ORDER BY candidate.created_at DESC,candidate.id DESC LIMIT 500) document
          WHERE document.id=line.document_id)),
    'allocations',(SELECT COALESCE(jsonb_agg(to_jsonb(allocation)
      ORDER BY allocation.created_at,allocation.id),'[]'::JSONB)
      FROM public.supplier_invoice_allocations allocation
      WHERE allocation.company_id=v_company AND EXISTS(SELECT 1
        FROM (SELECT candidate.id FROM public.supplier_invoice_documents candidate
          WHERE candidate.company_id=v_company
          ORDER BY candidate.created_at DESC,candidate.id DESC LIMIT 500) document
        WHERE document.id=allocation.document_id)),
    'toleranceResults',(SELECT COALESCE(jsonb_agg(to_jsonb(result)
      ORDER BY result.created_at,result.id),'[]'::JSONB)
      FROM public.supplier_invoice_tolerance_results result
      WHERE result.company_id=v_company AND EXISTS(SELECT 1
        FROM (SELECT candidate.id FROM public.supplier_invoice_documents candidate
          WHERE candidate.company_id=v_company
          ORDER BY candidate.created_at DESC,candidate.id DESC LIMIT 500) document
        WHERE document.id=result.document_id)),
    'policies',(SELECT COALESCE(jsonb_agg(to_jsonb(policy)
      ORDER BY policy.is_active DESC,policy.effective_from DESC,policy.id),
      '[]'::JSONB) FROM public.supplier_invoice_tolerance_policies policy
      WHERE policy.company_id=v_company),
    'openApProvisionals',(SELECT COALESCE(jsonb_agg(
      to_jsonb(provisional)||jsonb_build_object(
        'goods_receipt_documents',jsonb_build_object(
          'id',receipt.id,'receipt_no',receipt.receipt_no,
          'supplier_delivery_no',receipt.supplier_delivery_no,
          'received_at',receipt.received_at,'status',receipt.status),
        'goods_receipt_lines',jsonb_build_object(
          'id',line.id,'product_id',line.product_id,
          'accepted_good_base_qty',line.accepted_good_base_qty,
          'damaged_base_qty',line.damaged_base_qty,
          'estimated_base_unit_cost',line.estimated_base_unit_cost,
          'product_sku_snapshot',line.product_sku_snapshot,
          'product_name_snapshot',line.product_name_snapshot,
          'base_uom_name_snapshot',line.base_uom_name_snapshot))
      ORDER BY receipt.received_at DESC,provisional.id),'[]'::JSONB)
      FROM public.goods_receipt_ap_provisionals provisional
      JOIN public.goods_receipt_documents receipt
        ON receipt.company_id=provisional.company_id
       AND receipt.id=provisional.receipt_id AND receipt.status='POSTED'
      JOIN public.goods_receipt_lines line
        ON line.company_id=provisional.company_id
       AND line.id=provisional.receipt_line_id
      WHERE provisional.company_id=v_company AND provisional.status='OPEN'),
    'suppliers',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',supplier.id,'supplier_code',supplier.supplier_code,
      'supplier_name',supplier.supplier_name,'is_active',supplier.is_active)
      ORDER BY supplier.supplier_name,supplier.id),'[]'::JSONB)
      FROM public.suppliers supplier WHERE supplier.company_id=v_company),
    'products',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',product.id,'sku',product.sku,'name',product.name,
      'uom_id',product.uom_id,'is_active',product.is_active,
      'is_bundle',product.is_bundle) ORDER BY product.name,product.id),
      '[]'::JSONB) FROM public.products product
      WHERE product.company_id=v_company AND product.is_active
        AND NOT product.is_bundle),
    'productUoms',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'product_id',product_uom.product_id,'uom_id',product_uom.uom_id,
      'factor_to_base',product_uom.factor_to_base,
      'is_active',product_uom.is_active,'uoms',jsonb_build_object(
        'id',uom.id,'name',uom.name,'allow_decimal',uom.allow_decimal,
        'decimal_precision',uom.decimal_precision))
      ORDER BY product_uom.product_id,product_uom.factor_to_base,
        product_uom.uom_id),'[]'::JSONB)
      FROM public.product_uoms product_uom JOIN public.uoms uom
        ON uom.company_id=product_uom.company_id
       AND uom.id=product_uom.uom_id
      JOIN public.products product ON product.company_id=product_uom.company_id
       AND product.id=product_uom.product_id
      WHERE product_uom.company_id=v_company AND product_uom.is_active
        AND uom.is_active AND product.is_active AND NOT product.is_bundle),
    'taxRules',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',rule.id,'tax_code',rule.tax_code,'tax_name',rule.tax_name,
      'tax_scope',rule.tax_scope,'is_active',rule.is_active,
      'tax_rule_versions',jsonb_build_array(jsonb_build_object(
        'id',version.id,'tax_rule_id',version.tax_rule_id,
        'rate_percent',version.rate_percent,
        'calculation_scope',version.calculation_scope,
        'status',version.status))) ORDER BY rule.tax_name,rule.id),
      '[]'::JSONB) FROM public.tax_rules rule
      JOIN public.tax_rule_versions version ON version.company_id=rule.company_id
       AND version.tax_rule_id=rule.id AND version.status='ACTIVE'
      WHERE rule.company_id=v_company AND rule.tax_scope='PURCHASE'
        AND rule.is_active),
    'profiles',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',profile.id,'name',profile.name) ORDER BY profile.name,profile.id),
      '[]'::JSONB) FROM public.profiles profile WHERE EXISTS(SELECT 1
        FROM public.supplier_invoice_documents document
        WHERE document.company_id=v_company AND profile.id IN(
          document.created_by,document.validated_by,document.canceled_by)))
  );
END
$$;

CREATE FUNCTION public.get_supplier_payment_invoice_references()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.supplier_payments','VIEW');
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'id',invoice.id,'invoice_no',invoice.invoice_no,
    'supplier_id',invoice.supplier_id,
    'supplier_invoice_no',invoice.supplier_invoice_no,
    'invoice_date',invoice.invoice_date,'due_date',invoice.due_date,
    'grand_total',invoice.grand_total,'status',invoice.status,
    'matching_status',invoice.matching_status,'created_at',invoice.created_at,
    'paid_amount',COALESCE(paid.amount,0),
    'remaining_balance',GREATEST(invoice.grand_total-COALESCE(paid.amount,0),0))
    ORDER BY invoice.created_at DESC,invoice.id DESC)
    FROM public.supplier_invoice_documents invoice
    LEFT JOIN LATERAL(SELECT sum(allocation.allocated_amount) amount
      FROM public.supplier_payment_allocations allocation
      JOIN public.supplier_payment_documents payment
        ON payment.company_id=allocation.company_id
       AND payment.id=allocation.document_id AND payment.status='VALIDATED'
      WHERE allocation.company_id=invoice.company_id
        AND allocation.invoice_id=invoice.id) paid ON TRUE
    WHERE invoice.company_id=v_company AND invoice.status='VALIDATED'),
    '[]'::JSONB);
END
$$;

CREATE FUNCTION public.get_purchase_return_invoice_references()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.purchase_returns','VIEW');
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'id',invoice.id,'invoice_no',invoice.invoice_no,
    'supplier_id',invoice.supplier_id,
    'supplier_invoice_no',invoice.supplier_invoice_no,
    'invoice_date',invoice.invoice_date,'status',invoice.status,
    'matching_status',invoice.matching_status,'grand_total',invoice.grand_total)
    ORDER BY invoice.invoice_date DESC,invoice.id DESC)
    FROM public.supplier_invoice_documents invoice
    WHERE invoice.company_id=v_company AND invoice.status='VALIDATED'
      AND EXISTS(SELECT 1 FROM public.supplier_invoice_allocations allocation
        JOIN public.goods_receipt_lines receipt_line
          ON receipt_line.company_id=allocation.company_id
         AND receipt_line.id=allocation.receipt_line_id
        JOIN public.goods_receipt_documents receipt
          ON receipt.company_id=receipt_line.company_id
         AND receipt.id=receipt_line.document_id
        WHERE allocation.company_id=invoice.company_id
          AND allocation.document_id=invoice.id
          AND EXISTS(SELECT 1 FROM public.purchase_return_lines return_line
            JOIN public.purchase_return_documents return_document
              ON return_document.company_id=return_line.company_id
             AND return_document.id=return_line.document_id
            WHERE return_line.company_id=v_company
              AND return_line.source_receipt_line_id=receipt_line.id))),
    '[]'::JSONB);
END
$$;

CREATE FUNCTION public.export_finance_supplier_invoices(
  p_from TIMESTAMPTZ,p_to TIMESTAMPTZ
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.supplier_invoices','EXPORT');
  IF p_from IS NULL OR p_to IS NULL OR p_from>p_to THEN
    RAISE EXCEPTION 'SUPPLIER_INVOICE_EXPORT_PERIOD_INVALID';
  END IF;
  RETURN jsonb_build_object(
    'periodFrom',p_from,'periodTo',p_to,
    'documentCount',(SELECT count(*) FROM public.supplier_invoice_documents d
      WHERE d.company_id=v_company AND d.invoice_date BETWEEN p_from::DATE AND p_to::DATE),
    'grandTotal',(SELECT COALESCE(sum(d.grand_total),0)
      FROM public.supplier_invoice_documents d WHERE d.company_id=v_company
        AND d.status='VALIDATED'
        AND d.invoice_date BETWEEN p_from::DATE AND p_to::DATE),
    'rows',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'invoiceNo',document.invoice_no,
      'supplierInvoiceNo',document.supplier_invoice_no,
      'supplierName',supplier.supplier_name,
      'invoiceDate',document.invoice_date,'dueDate',document.due_date,
      'documentStatus',document.status,'matchingStatus',document.matching_status,
      'productSku',line.product_sku_snapshot,
      'productName',line.product_name_snapshot,
      'uomName',line.invoice_uom_name_snapshot,
      'invoiceQty',line.invoice_qty,'allocatedBaseQty',line.allocated_base_qty,
      'unitPrice',line.unit_price_input,'subtotal',line.subtotal_before_tax,
      'taxAmount',line.tax_amount,'lineTotal',line.line_total,
      'purchasePriceVariance',document.purchase_price_variance,
      'validatedAt',document.validated_at)
      ORDER BY document.invoice_date,document.invoice_no,line.line_no),
      '[]'::JSONB)
      FROM public.supplier_invoice_documents document
      JOIN public.suppliers supplier ON supplier.company_id=document.company_id
       AND supplier.id=document.supplier_id
      JOIN public.supplier_invoice_lines line
        ON line.company_id=document.company_id AND line.document_id=document.id
      WHERE document.company_id=v_company
        AND document.invoice_date BETWEEN p_from::DATE AND p_to::DATE)
  );
END
$$;

-- Preserve the latest proven G5 transaction bodies behind capability wrappers.
ALTER FUNCTION public.save_supplier_invoice_tolerance_policy(
  UUID,BIGINT,UUID,NUMERIC,NUMERIC,NUMERIC,NUMERIC,DATE,BOOLEAN)
  SET SCHEMA private;
ALTER FUNCTION private.save_supplier_invoice_tolerance_policy(
  UUID,BIGINT,UUID,NUMERIC,NUMERIC,NUMERIC,NUMERIC,DATE,BOOLEAN)
  RENAME TO acp6e_save_supplier_invoice_tolerance_policy_core;
ALTER FUNCTION public.save_supplier_invoice_draft(
  UUID,BIGINT,UUID,TEXT,DATE,DATE,TEXT,TEXT,TEXT,JSONB) SET SCHEMA private;
ALTER FUNCTION private.save_supplier_invoice_draft(
  UUID,BIGINT,UUID,TEXT,DATE,DATE,TEXT,TEXT,TEXT,JSONB)
  RENAME TO acp6e_save_supplier_invoice_draft_core;
ALTER FUNCTION public.validate_supplier_invoice(UUID,BIGINT,UUID)
  SET SCHEMA private;
ALTER FUNCTION private.validate_supplier_invoice(UUID,BIGINT,UUID)
  RENAME TO acp6e_validate_supplier_invoice_core;
ALTER FUNCTION public.cancel_supplier_invoice(UUID,BIGINT,TEXT)
  SET SCHEMA private;
ALTER FUNCTION private.cancel_supplier_invoice(UUID,BIGINT,TEXT)
  RENAME TO acp6e_cancel_supplier_invoice_core;

CREATE FUNCTION public.save_supplier_invoice_tolerance_policy(
  p_policy_id UUID,p_master_version BIGINT,p_supplier_id UUID,
  p_quantity_tolerance_percent NUMERIC,
  p_quantity_tolerance_base_qty NUMERIC,
  p_value_tolerance_percent NUMERIC,p_value_tolerance_amount NUMERIC,
  p_effective_from DATE,p_is_active BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.supplier_invoices','APPROVE');
  RETURN private.acp6e_save_supplier_invoice_tolerance_policy_core(
    p_policy_id,p_master_version,p_supplier_id,p_quantity_tolerance_percent,
    p_quantity_tolerance_base_qty,p_value_tolerance_percent,
    p_value_tolerance_amount,p_effective_from,p_is_active);
END
$$;

CREATE FUNCTION public.save_supplier_invoice_draft(
  p_document_id UUID,p_master_version BIGINT,p_supplier_id UUID,
  p_supplier_invoice_no TEXT,p_invoice_date DATE,p_due_date DATE,
  p_price_mode TEXT,p_notes TEXT,p_evidence_url TEXT,p_lines JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.supplier_invoices',CASE WHEN p_document_id IS NULL
      THEN 'CREATE_DRAFT' ELSE 'EDIT_DRAFT' END);
  RETURN private.acp6e_save_supplier_invoice_draft_core(
    p_document_id,p_master_version,p_supplier_id,p_supplier_invoice_no,
    p_invoice_date,p_due_date,p_price_mode,p_notes,p_evidence_url,p_lines);
END
$$;

CREATE FUNCTION public.validate_supplier_invoice(
  p_document_id UUID,p_master_version BIGINT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.supplier_invoices','POST');
  RETURN private.acp6e_validate_supplier_invoice_core(
    p_document_id,p_master_version,p_idempotency_key);
END
$$;

CREATE FUNCTION public.cancel_supplier_invoice(
  p_document_id UUID,p_master_version BIGINT,p_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.supplier_invoices','EDIT_DRAFT');
  RETURN private.acp6e_cancel_supplier_invoice_core(
    p_document_id,p_master_version,p_reason);
END
$$;

UPDATE public.access_permission_catalog SET
  enforcement_status='ENFORCED',catalog_version=catalog_version+1,
  updated_at=clock_timestamp()
WHERE permission_key='finance.supplier_invoices'
  AND enforcement_status='SHADOW';

REVOKE SELECT ON public.supplier_invoice_tolerance_policies,
  public.supplier_invoice_documents,public.supplier_invoice_lines,
  public.supplier_invoice_allocations,
  public.supplier_invoice_tolerance_results,public.supplier_invoice_audit
FROM authenticated;

REVOKE ALL ON FUNCTION
  private.acp6e_save_supplier_invoice_tolerance_policy_core(
    UUID,BIGINT,UUID,NUMERIC,NUMERIC,NUMERIC,NUMERIC,DATE,BOOLEAN),
  private.acp6e_save_supplier_invoice_draft_core(
    UUID,BIGINT,UUID,TEXT,DATE,DATE,TEXT,TEXT,TEXT,JSONB),
  private.acp6e_validate_supplier_invoice_core(UUID,BIGINT,UUID),
  private.acp6e_cancel_supplier_invoice_core(UUID,BIGINT,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.acp6e_save_supplier_invoice_tolerance_policy_core(
    UUID,BIGINT,UUID,NUMERIC,NUMERIC,NUMERIC,NUMERIC,DATE,BOOLEAN),
  private.acp6e_save_supplier_invoice_draft_core(
    UUID,BIGINT,UUID,TEXT,DATE,DATE,TEXT,TEXT,TEXT,JSONB),
  private.acp6e_validate_supplier_invoice_core(UUID,BIGINT,UUID),
  private.acp6e_cancel_supplier_invoice_core(UUID,BIGINT,TEXT)
TO service_role;

REVOKE ALL ON FUNCTION public.get_finance_supplier_invoices(),
  public.get_supplier_payment_invoice_references(),
  public.get_purchase_return_invoice_references(),
  public.export_finance_supplier_invoices(TIMESTAMPTZ,TIMESTAMPTZ),
  public.save_supplier_invoice_tolerance_policy(
    UUID,BIGINT,UUID,NUMERIC,NUMERIC,NUMERIC,NUMERIC,DATE,BOOLEAN),
  public.save_supplier_invoice_draft(
    UUID,BIGINT,UUID,TEXT,DATE,DATE,TEXT,TEXT,TEXT,JSONB),
  public.validate_supplier_invoice(UUID,BIGINT,UUID),
  public.cancel_supplier_invoice(UUID,BIGINT,TEXT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_finance_supplier_invoices(),
  public.get_supplier_payment_invoice_references(),
  public.get_purchase_return_invoice_references(),
  public.export_finance_supplier_invoices(TIMESTAMPTZ,TIMESTAMPTZ),
  public.save_supplier_invoice_tolerance_policy(
    UUID,BIGINT,UUID,NUMERIC,NUMERIC,NUMERIC,NUMERIC,DATE,BOOLEAN),
  public.save_supplier_invoice_draft(
    UUID,BIGINT,UUID,TEXT,DATE,DATE,TEXT,TEXT,TEXT,JSONB),
  public.validate_supplier_invoice(UUID,BIGINT,UUID),
  public.cancel_supplier_invoice(UUID,BIGINT,TEXT)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260813110000','acp_phase6e_supplier_invoice_permission_enforcement',
  'Supplier Invoice composed read/export and capability enforcement with independent Supplier Payment references while Finance events remain HOLD');

COMMIT;
