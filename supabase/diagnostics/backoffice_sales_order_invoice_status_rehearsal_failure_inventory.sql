-- Read-only clone inventory after rollback-only unit 72 fixture failure.
SELECT 'invoice_dp_overage_runtime' check_name,'INFO' status,
  jsonb_build_object(
    'coreSetsOverageEvenOnDp',position(
      $marker$set_config('kgs.backoffice_invoice_accepted_overage_lines',v_overage::text,true)$marker$
      in pg_get_functiondef(to_regprocedure(
        'private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)')))>0,
    'triggerRejectsNonRegular',position($marker$NEW.invoice_type<>'REGULAR'$marker$
      in pg_get_functiondef(to_regprocedure(
        'private.trg_backoffice_sales_invoice_accepted_overage_lines()')))>0,
    'unit72LedgerRows',(SELECT count(*) FROM private.kgs_schema_migrations WHERE version='20260912140000'),
    'orders',(SELECT count(*) FROM public.backoffice_sales_orders),
    'invoices',(SELECT count(*) FROM public.backoffice_sales_invoices),
    'deliveryOrders',(SELECT count(*) FROM public.backoffice_sales_delivery_orders),
    'receipts',(SELECT count(*) FROM public.backoffice_sales_delivery_receipts)) details;
