-- Read-only postflight for 20260918160000.
WITH checks AS (
  SELECT 'invoice_return_status_migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260918160000'
  UNION ALL
  SELECT 'invoice_return_status_routine_contract',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-2)::bigint,jsonb_build_object('present',count(*),'expected',2)
  FROM (VALUES
    (to_regprocedure('private.derive_sales_invoice_commercial_status(boolean,numeric,numeric,boolean)')),
    (to_regprocedure('public.get_sales_invoice_commercial_statuses()'))
  ) routine(signature) WHERE signature IS NOT NULL
  UNION ALL
  SELECT 'invoice_return_status_permission_contract',
    CASE WHEN has_function_privilege('authenticated',
      'public.get_sales_invoice_commercial_statuses()','EXECUTE')
      AND NOT has_function_privilege('authenticated',
      'private.derive_sales_invoice_commercial_status(boolean,numeric,numeric,boolean)','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN has_function_privilege('authenticated',
      'public.get_sales_invoice_commercial_statuses()','EXECUTE')
      AND NOT has_function_privilege('authenticated',
      'private.derive_sales_invoice_commercial_status(boolean,numeric,numeric,boolean)','EXECUTE')
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('publicAuthenticated',has_function_privilege('authenticated',
      'public.get_sales_invoice_commercial_statuses()','EXECUTE'),
      'privateAuthenticated',has_function_privilege('authenticated',
      'private.derive_sales_invoice_commercial_status(boolean,numeric,numeric,boolean)','EXECUTE'))
  UNION ALL
  SELECT 'invoice_return_status_authorization_boundary',
    CASE WHEN position('sales.sales_documents' in definition)>0
      AND position('sales.backoffice_orders' in definition)>0
      AND position('private_request_company_matches' in definition)>0
      AND position('CUSTOM_PERMISSION_DENIED' in definition)>0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('sales.sales_documents' in definition)>0
      AND position('sales.backoffice_orders' in definition)>0
      AND position('private_request_company_matches' in definition)>0
      AND position('CUSTOM_PERMISSION_DENIED' in definition)>0
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('retailView',position('sales.sales_documents' in definition)>0,
      'backofficeView',position('sales.backoffice_orders' in definition)>0,
      'activeCompany',position('private_request_company_matches' in definition)>0)
  FROM (SELECT pg_get_functiondef(
    'public.get_sales_invoice_commercial_statuses()'::regprocedure) definition) runtime
  UNION ALL
  SELECT 'invoice_return_status_runtime_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM (
    SELECT sale.id
    FROM public.sales_headers sale
    JOIN public.sales_invoice_snapshots invoice
      ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
    LEFT JOIN LATERAL(SELECT round(COALESCE(sum(document.refund_total)
      FILTER(WHERE document.status='POSTED'),0),4) native_amount
      FROM public.sales_return_documents document
      WHERE document.company_id=sale.company_id AND document.source_sales_id=sale.id) native ON true
    LEFT JOIN LATERAL(SELECT round(COALESCE(sum(note.grand_total)
      FILTER(WHERE note.status='POSTED'),0),4) bridge_amount
      FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=sale.company_id AND note.source_kind='RETAINED_RETAIL'
        AND note.source_retail_sales_id=sale.id) bridge ON true
    WHERE COALESCE(native.native_amount,0)+COALESCE(bridge.bridge_amount,0)<0
  ) invalid
  UNION ALL
  SELECT 'invoice_return_status_runtime_inventory','INFO',0::bigint,
    jsonb_build_object('postedRetailCredits',(SELECT count(*)
      FROM public.backoffice_sales_credit_notes
      WHERE source_kind='RETAINED_RETAIL' AND status='POSTED'),
      'postedBackofficeCredits',(SELECT count(*)
      FROM public.backoffice_sales_credit_notes
      WHERE source_kind='BACKOFFICE' AND status='POSTED'))
)
SELECT * FROM checks ORDER BY status,check_name;
