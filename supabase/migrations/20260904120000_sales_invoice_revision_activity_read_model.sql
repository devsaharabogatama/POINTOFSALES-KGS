-- Human-readable Sales Invoice activity and revision linkage read model.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260903120000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: revision idempotency runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260904120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260904120000';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION public.get_sales_order_revision_links()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_documents','VIEW');
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'revisionId',revision.id,'status',revision.status,
      'reason',revision.reason,'sourceSalesId',revision.source_sales_id,
      'sourceOrderNo',source.draft_no,'sourceInvoiceNo',source.invoice_no,
      'replacementSalesId',revision.replacement_sales_id,
      'replacementOrderNo',replacement.draft_no,
      'replacementInvoiceNo',replacement.invoice_no,
      'startedByName',COALESCE(starter.name,'Pengguna'),
      'startedAt',revision.started_at,
      'appliedByName',applier.name,'appliedAt',revision.applied_at,
      'abandonedByName',abandoner.name,'abandonedAt',revision.abandoned_at,
      'abandonedReason',revision.abandoned_reason,
      'updatedAt',revision.updated_at)
    ORDER BY revision.created_at DESC)
    FROM (SELECT candidate.* FROM public.sales_order_revisions candidate
      WHERE candidate.company_id=v_company
      ORDER BY candidate.created_at DESC,candidate.id LIMIT 500) revision
    JOIN public.sales_headers source ON source.company_id=revision.company_id
      AND source.id=revision.source_sales_id
    JOIN public.sales_headers replacement
      ON replacement.company_id=revision.company_id
      AND replacement.id=revision.replacement_sales_id
    LEFT JOIN public.profiles starter ON starter.id=revision.started_by
    LEFT JOIN public.profiles applier ON applier.id=revision.applied_by
    LEFT JOIN public.profiles abandoner ON abandoner.id=revision.abandoned_by
    ),'[]'::JSONB);
END
$$;

CREATE OR REPLACE FUNCTION public.get_sales_document_activity()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_documents','VIEW');
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'salesId',sale.id,
      'createdAt',sale.created_at,
      'createdByName',COALESCE(creator.name,'Pengguna'),
      'updatedAt',sale.updated_at,
      'confirmedAt',sale.confirmed_at,
      'confirmedByName',confirmer.name,
      'canceledAt',sale.canceled_at,
      'canceledByName',canceler.name)
    ORDER BY invoice.created_at DESC,invoice.id)
    FROM (SELECT candidate.* FROM public.sales_invoice_snapshots candidate
      WHERE candidate.company_id=v_company
      ORDER BY candidate.created_at DESC,candidate.id LIMIT 500) invoice
    JOIN public.sales_headers sale ON sale.company_id=invoice.company_id
      AND sale.id=invoice.sales_id
    LEFT JOIN public.profiles creator ON creator.id=sale.created_by
    LEFT JOIN public.profiles confirmer ON confirmer.id=sale.confirmed_by
    LEFT JOIN public.profiles canceler ON canceler.id=sale.canceled_by
    ),'[]'::JSONB);
END
$$;

REVOKE ALL ON FUNCTION public.get_sales_order_revision_links(),
  public.get_sales_document_activity() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_sales_order_revision_links(),
  public.get_sales_document_activity() TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260904120000','sales_invoice_revision_activity_read_model',
  'Expose guarded human-readable Sales Invoice lifecycle timestamps, actors and bidirectional revision document linkage without changing operational effects');

NOTIFY pgrst,'reload schema';
COMMIT;
