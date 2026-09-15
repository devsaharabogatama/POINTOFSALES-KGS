-- Read-only closing inventory for isolated Development client activation.
SELECT jsonb_build_object(
  'target','isolated-development',
  'enabledCompanies',(SELECT count(*) FROM public.company_features
    WHERE feature_code='backoffice_delivered_qty_sales_enabled' AND is_enabled),
  'orders',(SELECT count(*) FROM public.backoffice_sales_orders),
  'reservations',(SELECT count(*) FROM public.sales_stock_reservations),
  'deliveries',(SELECT count(*) FROM public.sales_delivery_documents),
  'invoices',(SELECT count(*) FROM public.sales_invoice_snapshots),
  'stockMovements',(SELECT count(*) FROM public.stock_movements),
  'paymentRequests',(SELECT count(*) FROM public.sales_payment_verification_requests),
  'financialEvents',(SELECT count(*) FROM public.financial_events),
  'activeFinanceQueues',(SELECT count(*) FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')),
  'permission',(SELECT enforcement_status FROM public.access_permission_catalog
    WHERE permission_key='sales.backoffice_orders')
) AS closing_state;
