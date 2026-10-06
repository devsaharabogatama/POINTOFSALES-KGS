-- STAGING DEVELOPMENT CANDIDATE. Effective UI and payment consumers only.
ALTER FUNCTION public.get_backoffice_sales_invoice_ui(uuid)
  RENAME TO get_backoffice_sales_invoice_ui_before_unified_revision;
CREATE FUNCTION public.get_backoffice_sales_invoice_ui(p_invoice_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp SET statement_timeout='8s' AS $ui$
DECLARE c uuid:=public.private_active_company_id();base jsonb;context jsonb;customer_snapshot jsonb;
BEGIN
 base:=public.get_backoffice_sales_invoice_ui_before_unified_revision(p_invoice_id);
 context:=public.get_backoffice_invoice_revision_context(p_invoice_id);
 SELECT jsonb_build_object('id',cu.id,'code',cu.code,'name',cu.name,'phone',cu.phone,
   'email',cu.email,'address',cu.address) INTO STRICT customer_snapshot
 FROM public.customers cu WHERE cu.company_id=c AND cu.id=(context->'effectiveIdentity'->>'customerId')::uuid;
 RETURN base||jsonb_build_object('data',(base->'data')||jsonb_build_object(
   'customerId',context->'effectiveIdentity'->>'customerId','customerSnapshot',customer_snapshot,
   'invoiceDate',context->'effectiveIdentity'->>'invoiceDate',
   'dueDate',context->'schedules'->0->>'due_date','effectiveGrandTotal',context->'effectiveTotal',
   'invoiceRevision',context->'revision','revisionHistory',context->'history'));
END
$ui$;

ALTER FUNCTION public.get_backoffice_sales_invoice_payment_context(uuid)
  RENAME TO get_backoffice_sales_invoice_payment_context_before_unified_revision;
CREATE FUNCTION public.get_backoffice_sales_invoice_payment_context(p_invoice_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp SET statement_timeout='8s' AS $payment$
DECLARE c uuid:=public.private_active_company_id();base jsonb;context jsonb;unified_refund numeric(24,4);
 total_refund numeric(24,4);refunded numeric(24,4);
BEGIN
 base:=public.get_backoffice_sales_invoice_payment_context_before_unified_revision(p_invoice_id);
 context:=public.get_backoffice_invoice_revision_context(p_invoice_id);
 SELECT round(COALESCE(sum((r.execution_plan->'amountJournal'->>'refundLiabilityDelta')::numeric),0),4)
 INTO unified_refund FROM private.backoffice_invoice_revisions r
 WHERE r.company_id=c AND r.invoice_id=p_invoice_id;
 total_refund:=(base->'summary'->>'refundLiabilityAmount')::numeric+unified_refund;
 refunded:=(base->'summary'->>'refundedAmount')::numeric;
 RETURN base||jsonb_build_object('effectiveIdentity',context->'effectiveIdentity',
   'customer',context->'customer','invoiceRevision',context->'revision',
   'invoiceRevisions',context->'history','summary',(base->'summary')||jsonb_build_object(
     'unifiedRevisionRefundLiabilityAmount',unified_refund,
     'refundLiabilityAmount',total_refund,'remainingRefundLiability',greatest(0,total_refund-refunded),
     'status',CASE WHEN greatest(0,total_refund-refunded)>0 THEN 'REFUND_PENDING'
       ELSE base->'summary'->>'status' END));
END
$payment$;

REVOKE ALL ON FUNCTION public.get_backoffice_sales_invoice_ui_before_unified_revision(uuid),
 public.get_backoffice_sales_invoice_payment_context_before_unified_revision(uuid),
 public.get_backoffice_sales_invoice_ui(uuid),public.get_backoffice_sales_invoice_payment_context(uuid)
 FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_backoffice_sales_invoice_ui(uuid),
 public.get_backoffice_sales_invoice_payment_context(uuid) TO authenticated,service_role;
