-- ACP-6F: Supplier Payment effective permission, bounded read/export, eligible
-- source-account validation, and Draft-only cancellation. Finance remains HOLD.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813110000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-6E required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
    WHERE permission_key='finance.supplier_payments'
      AND enforcement_status='SHADOW')<>1 THEN
    RAISE EXCEPTION 'SUPPLIER_PAYMENT_PERMISSION_NOT_SHADOW';
  END IF;
  IF EXISTS(SELECT 1 FROM public.supplier_payment_documents document
    LEFT JOIN public.financial_events event
      ON event.company_id=document.company_id
     AND event.id=document.financial_event_id
    WHERE document.status='VALIDATED' AND (event.id IS NULL
      OR event.source_table<>'supplier_payment_documents'
      OR event.source_id<>document.id
      OR event.event_type<>'SUPPLIER_PAYMENT_VALIDATED'::public.event_type)) THEN
    RAISE EXCEPTION 'SUPPLIER_PAYMENT_EVENT_HISTORY_NOT_RECONCILED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.financial_events
    WHERE source_table='supplier_payment_documents' AND status<>'HOLD') THEN
    RAISE EXCEPTION 'SUPPLIER_PAYMENT_FINANCE_EVENT_NOT_HOLD';
  END IF;
END
$guard$;

CREATE FUNCTION private.acp6f_source_account_allowed(
  p_company UUID,p_account UUID,p_method TEXT
) RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT p_account IS NOT NULL AND EXISTS(
    SELECT 1 FROM public.chart_of_accounts account
    WHERE account.company_id=p_company AND account.id=p_account
      AND account.is_active AND account.is_postable
      AND account.account_type='ASSET'
      AND (account.system_function_key=CASE WHEN p_method='CASH'
            THEN 'MAIN_CASH' ELSE 'BANK' END
        OR EXISTS(SELECT 1 FROM public.company_account_function_fallbacks fallback
          WHERE fallback.company_id=p_company
            AND fallback.account_id=account.id
            AND fallback.account_function_key=CASE WHEN p_method='CASH'
              THEN 'MAIN_CASH' ELSE 'BANK' END
            AND fallback.status='ACTIVE'
            AND fallback.effective_from<=clock_timestamp()
            AND (fallback.effective_to IS NULL
              OR fallback.effective_to>clock_timestamp()))
        OR EXISTS(SELECT 1 FROM public.transaction_account_rules rule
          JOIN public.transaction_categories category
            ON category.company_id=rule.company_id
           AND category.id=rule.transaction_category_id
          WHERE rule.company_id=p_company AND rule.account_id=account.id
            AND category.system_key='SUPPLIER_PAYMENT'
            AND rule.account_function_key=CASE WHEN p_method='CASH'
              THEN 'MAIN_CASH' ELSE 'BANK' END
            AND rule.status='ACTIVE'
            AND rule.effective_from<=clock_timestamp()
            AND (rule.effective_to IS NULL
              OR rule.effective_to>clock_timestamp())))
  );
$$;

CREATE FUNCTION public.get_finance_supplier_payments()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_permission JSONB;
BEGIN
  v_permission:=private.acp_require_permission_capability(
    v_company,'finance.supplier_payments','VIEW');
  RETURN jsonb_build_object(
    'companyId',v_company,'currentUserId',auth.uid(),
    'effectiveCapabilities',COALESCE(
      v_permission->'effectiveCapabilities','[]'::JSONB),
    'documents',(SELECT COALESCE(jsonb_agg(to_jsonb(document)
      ORDER BY document.created_at DESC,document.id DESC),'[]'::JSONB)
      FROM (SELECT candidate.* FROM public.supplier_payment_documents candidate
        WHERE candidate.company_id=v_company ORDER BY candidate.created_at DESC,
          candidate.id DESC LIMIT 500) document),
    'allocations',(SELECT COALESCE(jsonb_agg(to_jsonb(allocation)
      ORDER BY allocation.document_id,allocation.created_at,allocation.id),
      '[]'::JSONB) FROM public.supplier_payment_allocations allocation
      WHERE allocation.company_id=v_company AND EXISTS(SELECT 1
        FROM (SELECT candidate.id FROM public.supplier_payment_documents candidate
          WHERE candidate.company_id=v_company ORDER BY candidate.created_at DESC,
          candidate.id DESC LIMIT 500) document
        WHERE document.id=allocation.document_id)),
    'validatedInvoices',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',invoice.id,'invoice_no',invoice.invoice_no,
      'supplier_id',invoice.supplier_id,
      'supplier_invoice_no',invoice.supplier_invoice_no,
      'invoice_date',invoice.invoice_date,'due_date',invoice.due_date,
      'grand_total',invoice.grand_total,'status',invoice.status,
      'matching_status',invoice.matching_status,'created_at',invoice.created_at,
      'paid_amount',COALESCE(paid.amount,0),
      'remaining_balance',GREATEST(invoice.grand_total-COALESCE(paid.amount,0),0))
      ORDER BY invoice.created_at DESC,invoice.id DESC),'[]'::JSONB)
      FROM public.supplier_invoice_documents invoice
      LEFT JOIN LATERAL(SELECT sum(allocation.allocated_amount) amount
        FROM public.supplier_payment_allocations allocation
        JOIN public.supplier_payment_documents payment
          ON payment.company_id=allocation.company_id
         AND payment.id=allocation.document_id AND payment.status='VALIDATED'
        WHERE allocation.company_id=invoice.company_id
          AND allocation.invoice_id=invoice.id) paid ON TRUE
      WHERE invoice.company_id=v_company AND invoice.status='VALIDATED'),
    'suppliers',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',supplier.id,'supplier_code',supplier.supplier_code,
      'supplier_name',supplier.supplier_name,'is_active',supplier.is_active)
      ORDER BY supplier.supplier_name,supplier.id),'[]'::JSONB)
      FROM public.suppliers supplier WHERE supplier.company_id=v_company
        AND supplier.is_active),
    'accounts',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',account.id,'account_code',account.account_code,
      'account_name',account.account_name,'account_type',account.account_type,
      'is_active',account.is_active) ORDER BY account.account_code,account.id),
      '[]'::JSONB) FROM public.chart_of_accounts account
      WHERE account.company_id=v_company AND account.is_active
        AND account.is_postable AND account.account_type='ASSET'
        AND (private.acp6f_source_account_allowed(v_company,account.id,'CASH')
          OR private.acp6f_source_account_allowed(
            v_company,account.id,'BANK_TRANSFER'))),
    'profiles',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',profile.id,'full_name',profile.name,'username',profile.name)
      ORDER BY profile.name,profile.id),'[]'::JSONB)
      FROM public.profiles profile WHERE EXISTS(SELECT 1
        FROM public.supplier_payment_documents document
        WHERE document.company_id=v_company AND profile.id IN(
          document.created_by,document.validated_by,document.canceled_by)))
  );
END
$$;

CREATE FUNCTION public.export_finance_supplier_payments(
  p_from TIMESTAMPTZ,p_to TIMESTAMPTZ
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.supplier_payments','EXPORT');
  IF p_from IS NULL OR p_to IS NULL OR p_from>p_to THEN
    RAISE EXCEPTION 'SUPPLIER_PAYMENT_EXPORT_PERIOD_INVALID';
  END IF;
  RETURN jsonb_build_object('periodFrom',p_from,'periodTo',p_to,
    'documentCount',(SELECT count(*) FROM public.supplier_payment_documents d
      WHERE d.company_id=v_company
        AND d.payment_date BETWEEN p_from::DATE AND p_to::DATE),
    'validatedTotal',(SELECT COALESCE(sum(d.total_amount),0)
      FROM public.supplier_payment_documents d WHERE d.company_id=v_company
        AND d.status='VALIDATED'
        AND d.payment_date BETWEEN p_from::DATE AND p_to::DATE),
    'rows',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'paymentNo',document.payment_no,'paymentDate',document.payment_date,
      'supplierName',supplier.supplier_name,
      'paymentMethod',document.payment_method,
      'sourceAccountCode',account.account_code,
      'sourceAccountName',account.account_name,
      'referenceNo',document.reference_no,'status',document.status,
      'totalAmount',document.total_amount,
      'invoiceNo',invoice.invoice_no,
      'supplierInvoiceNo',invoice.supplier_invoice_no,
      'allocatedAmount',allocation.allocated_amount,
      'validatedAt',document.validated_at)
      ORDER BY document.payment_date,document.payment_no,invoice.invoice_no),
      '[]'::JSONB) FROM public.supplier_payment_documents document
      JOIN public.suppliers supplier ON supplier.company_id=document.company_id
       AND supplier.id=document.supplier_id
      JOIN public.supplier_payment_allocations allocation
        ON allocation.company_id=document.company_id
       AND allocation.document_id=document.id
      JOIN public.supplier_invoice_documents invoice
        ON invoice.company_id=allocation.company_id
       AND invoice.id=allocation.invoice_id
      LEFT JOIN public.chart_of_accounts account
        ON account.company_id=document.company_id
       AND account.id=document.source_account_id
      WHERE document.company_id=v_company
        AND document.payment_date BETWEEN p_from::DATE AND p_to::DATE));
END
$$;

ALTER FUNCTION public.save_supplier_payment_draft(
  UUID,BIGINT,UUID,DATE,TEXT,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,JSONB)
  SET SCHEMA private;
ALTER FUNCTION private.save_supplier_payment_draft(
  UUID,BIGINT,UUID,DATE,TEXT,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,JSONB)
  RENAME TO acp6f_save_supplier_payment_draft_core;
ALTER FUNCTION public.validate_supplier_payment(UUID,BIGINT,UUID)
  SET SCHEMA private;
ALTER FUNCTION private.validate_supplier_payment(UUID,BIGINT,UUID)
  RENAME TO acp6f_validate_supplier_payment_core;
ALTER FUNCTION public.cancel_supplier_payment(UUID,BIGINT,TEXT)
  SET SCHEMA private;
ALTER FUNCTION private.cancel_supplier_payment(UUID,BIGINT,TEXT)
  RENAME TO acp6f_cancel_supplier_payment_core;

CREATE FUNCTION public.save_supplier_payment_draft(
  p_document_id UUID,p_master_version BIGINT,p_supplier_id UUID,
  p_payment_date DATE,p_payment_method TEXT,p_source_account_id UUID,
  p_supplier_bank_name TEXT,p_supplier_bank_account_no TEXT,
  p_supplier_bank_account_holder TEXT,p_reference_no TEXT,p_notes TEXT,
  p_evidence_url TEXT,p_allocations JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,
    'finance.supplier_payments',CASE WHEN p_document_id IS NULL
      THEN 'CREATE_DRAFT' ELSE 'EDIT_DRAFT' END);
  IF p_source_account_id IS NOT NULL AND NOT
      private.acp6f_source_account_allowed(
        v_company,p_source_account_id,p_payment_method) THEN
    RAISE EXCEPTION 'SUPPLIER_PAYMENT_SOURCE_ACCOUNT_INVALID';
  END IF;
  RETURN private.acp6f_save_supplier_payment_draft_core(
    p_document_id,p_master_version,p_supplier_id,p_payment_date,
    p_payment_method,p_source_account_id,p_supplier_bank_name,
    p_supplier_bank_account_no,p_supplier_bank_account_holder,p_reference_no,
    p_notes,p_evidence_url,p_allocations);
END
$$;

CREATE FUNCTION public.validate_supplier_payment(
  p_document_id UUID,p_master_version BIGINT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_document RECORD;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.supplier_payments','POST');
  SELECT document.payment_method,document.source_account_id INTO v_document
  FROM public.supplier_payment_documents document
  WHERE document.company_id=v_company AND document.id=p_document_id;
  IF FOUND AND v_document.source_account_id IS NOT NULL AND NOT
      private.acp6f_source_account_allowed(v_company,
        v_document.source_account_id,v_document.payment_method) THEN
    RAISE EXCEPTION 'SUPPLIER_PAYMENT_SOURCE_ACCOUNT_INVALID';
  END IF;
  RETURN private.acp6f_validate_supplier_payment_core(
    p_document_id,p_master_version,p_idempotency_key);
END
$$;

CREATE FUNCTION public.cancel_supplier_payment(
  p_document_id UUID,p_master_version BIGINT,p_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_status TEXT;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.supplier_payments','EDIT_DRAFT');
  SELECT document.status INTO v_status
  FROM public.supplier_payment_documents document
  WHERE document.company_id=v_company AND document.id=p_document_id;
  IF v_status IS NOT NULL AND v_status<>'DRAFT' THEN
    RAISE EXCEPTION 'FINAL_SUPPLIER_PAYMENT_IMMUTABLE';
  END IF;
  RETURN private.acp6f_cancel_supplier_payment_core(
    p_document_id,p_master_version,p_reason);
END
$$;

UPDATE public.access_permission_catalog SET enforcement_status='ENFORCED',
  catalog_version=catalog_version+1,updated_at=clock_timestamp()
WHERE permission_key='finance.supplier_payments'
  AND enforcement_status='SHADOW';

REVOKE SELECT ON public.supplier_payment_documents,
  public.supplier_payment_allocations,public.supplier_payment_audit
FROM authenticated;

REVOKE ALL ON FUNCTION private.acp6f_source_account_allowed(UUID,UUID,TEXT),
  private.acp6f_save_supplier_payment_draft_core(
    UUID,BIGINT,UUID,DATE,TEXT,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,JSONB),
  private.acp6f_validate_supplier_payment_core(UUID,BIGINT,UUID),
  private.acp6f_cancel_supplier_payment_core(UUID,BIGINT,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.acp6f_source_account_allowed(UUID,UUID,TEXT),
  private.acp6f_save_supplier_payment_draft_core(
    UUID,BIGINT,UUID,DATE,TEXT,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,JSONB),
  private.acp6f_validate_supplier_payment_core(UUID,BIGINT,UUID),
  private.acp6f_cancel_supplier_payment_core(UUID,BIGINT,TEXT)
TO service_role;

REVOKE ALL ON FUNCTION public.get_finance_supplier_payments(),
  public.export_finance_supplier_payments(TIMESTAMPTZ,TIMESTAMPTZ),
  public.save_supplier_payment_draft(
    UUID,BIGINT,UUID,DATE,TEXT,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,JSONB),
  public.validate_supplier_payment(UUID,BIGINT,UUID),
  public.cancel_supplier_payment(UUID,BIGINT,TEXT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_finance_supplier_payments(),
  public.export_finance_supplier_payments(TIMESTAMPTZ,TIMESTAMPTZ),
  public.save_supplier_payment_draft(
    UUID,BIGINT,UUID,DATE,TEXT,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,JSONB),
  public.validate_supplier_payment(UUID,BIGINT,UUID),
  public.cancel_supplier_payment(UUID,BIGINT,TEXT)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260813120000','acp_phase6f_supplier_payment_permission_enforcement',
  'Supplier Payment composed read/export, effective capability guards, eligible source-account validation, Draft-only cancellation, direct-read closure, and Finance HOLD preservation');

COMMIT;
