-- Forward fix: the unified Posted-Invoice revision consumers must not require
-- Posted state when the canonical Invoice detail route reads a Draft or a
-- non-regular Invoice. Read-only wrappers only; no business data mutation.
BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended(
  '20261110120000_backoffice_draft_invoice_detail_revision_partition_fix',0));

DO $guard$
BEGIN
  IF EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20261110120000'
  ) THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_INSTALLED: 20261110120000';
  END IF;

  IF EXISTS(
    SELECT 1
    FROM (VALUES
      ('20261006140000'),
      ('20261105110000'),
      ('20261105120000')
    ) required(version)
    LEFT JOIN private.kgs_schema_migrations installed
      ON installed.version=required.version
    WHERE installed.version IS NULL
  ) THEN
    RAISE EXCEPTION 'MIGRATION_DEPENDENCY_MISSING';
  END IF;

  IF to_regprocedure('public.get_backoffice_sales_invoice_ui(uuid)') IS NULL
    OR to_regprocedure(
      'public.get_backoffice_sales_invoice_ui_before_unified_revision(uuid)') IS NULL
    OR to_regprocedure(
      'public.get_backoffice_sales_invoice_payment_context(uuid)') IS NULL
    OR to_regprocedure(
      'public.get_backoffice_sales_invoice_payment_context_before_unified_revision(uuid)') IS NULL
    OR to_regprocedure('public.get_backoffice_invoice_revision_context(uuid)') IS NULL
  THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice consumer runtime missing';
  END IF;

  IF md5(pg_get_functiondef(
      'public.get_backoffice_sales_invoice_ui(uuid)'::regprocedure))
      <> 'ae46ab9d5fe5d1d9b34ddc90cf807bdb'
    OR md5(pg_get_functiondef(
      'public.get_backoffice_sales_invoice_payment_context(uuid)'::regprocedure))
      <> 'dbe5b9307343bd03e6ea61a36490c692'
  THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice consumer anchor changed';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION public.get_backoffice_sales_invoice_ui(
  p_invoice_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp
SET statement_timeout='8s'
AS $ui$
DECLARE
  c uuid:=public.private_active_company_id();
  base jsonb;
  context jsonb;
  customer_snapshot jsonb;
  invoice_status text;
  invoice_type text;
BEGIN
  base:=public.get_backoffice_sales_invoice_ui_before_unified_revision(
    p_invoice_id);

  SELECT invoice.status,invoice.invoice_type
  INTO STRICT invoice_status,invoice_type
  FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=c AND invoice.id=p_invoice_id;

  IF invoice_status<>'POSTED' OR invoice_type<>'REGULAR' THEN
    RETURN base;
  END IF;

  context:=public.get_backoffice_invoice_revision_context(p_invoice_id);
  SELECT jsonb_build_object(
    'id',customer.id,
    'code',customer.code,
    'name',customer.name,
    'phone',customer.phone,
    'email',customer.email,
    'address',customer.address
  )
  INTO STRICT customer_snapshot
  FROM public.customers customer
  WHERE customer.company_id=c
    AND customer.id=(context->'effectiveIdentity'->>'customerId')::uuid;

  RETURN base||jsonb_build_object(
    'data',(base->'data')||jsonb_build_object(
      'customerId',context->'effectiveIdentity'->>'customerId',
      'customerSnapshot',customer_snapshot,
      'invoiceDate',context->'effectiveIdentity'->>'invoiceDate',
      'dueDate',context->'schedules'->0->>'due_date',
      'effectiveGrandTotal',context->'effectiveTotal',
      'invoiceRevision',context->'revision',
      'revisionHistory',context->'history'));
END
$ui$;

CREATE OR REPLACE FUNCTION public.get_backoffice_sales_invoice_payment_context(
  p_invoice_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp
SET statement_timeout='8s'
AS $payment$
DECLARE
  c uuid:=public.private_active_company_id();
  base jsonb;
  context jsonb;
  unified_refund numeric(24,4);
  total_refund numeric(24,4);
  refunded numeric(24,4);
  invoice_status text;
  invoice_type text;
BEGIN
  base:=public.get_backoffice_sales_invoice_payment_context_before_unified_revision(
    p_invoice_id);

  SELECT invoice.status,invoice.invoice_type
  INTO STRICT invoice_status,invoice_type
  FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=c AND invoice.id=p_invoice_id;

  IF invoice_status<>'POSTED' OR invoice_type<>'REGULAR' THEN
    RETURN base;
  END IF;

  context:=public.get_backoffice_invoice_revision_context(p_invoice_id);
  SELECT round(COALESCE(sum(
    (revision.execution_plan->'amountJournal'->>'refundLiabilityDelta')::numeric
  ),0),4)
  INTO unified_refund
  FROM private.backoffice_invoice_revisions revision
  WHERE revision.company_id=c AND revision.invoice_id=p_invoice_id;

  total_refund:=(base->'summary'->>'refundLiabilityAmount')::numeric
    +unified_refund;
  refunded:=(base->'summary'->>'refundedAmount')::numeric;

  RETURN base||jsonb_build_object(
    'effectiveIdentity',context->'effectiveIdentity',
    'customer',context->'customer',
    'invoiceRevision',context->'revision',
    'invoiceRevisions',context->'history',
    'summary',(base->'summary')||jsonb_build_object(
      'unifiedRevisionRefundLiabilityAmount',unified_refund,
      'refundLiabilityAmount',total_refund,
      'remainingRefundLiability',greatest(0,total_refund-refunded),
      'status',CASE
        WHEN greatest(0,total_refund-refunded)>0 THEN 'REFUND_PENDING'
        ELSE base->'summary'->>'status'
      END));
END
$payment$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
  '20261110120000',
  'backoffice_draft_invoice_detail_revision_partition_fix',
  'Partition effective Invoice UI/payment readers: Draft and non-regular use preserved base payload; Posted regular keeps unified revision overlay; no business data mutation'
);

NOTIFY pgrst,'reload schema';
COMMIT;
