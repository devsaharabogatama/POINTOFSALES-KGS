-- Sales document template alignment preflight. SELECT-only.
WITH checks AS (
  SELECT 'template_alignment_dependency' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('requiredVersion','20260827150000','ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260827150000'
  UNION ALL
  SELECT 'delivery_template_schema_state','SETUP',jsonb_build_object(
    'columnExists',EXISTS(SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='company_branding_profiles'
        AND column_name='delivery_signature_template'),
    'expectedModes',jsonb_build_array('WAREHOUSE','STORE'))
  UNION ALL
  SELECT 'sales_document_snapshot_inventory','INFO',jsonb_build_object(
    'invoiceSnapshots',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'deliveryDocuments',(SELECT count(*) FROM public.sales_delivery_documents),
    'deliverySnapshotsWithTemplate',(SELECT count(*)
      FROM public.sales_delivery_documents delivery
      WHERE delivery.snapshot_payload->'branding'->>'deliverySignatureTemplate'
        IN('WAREHOUSE','STORE')))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
