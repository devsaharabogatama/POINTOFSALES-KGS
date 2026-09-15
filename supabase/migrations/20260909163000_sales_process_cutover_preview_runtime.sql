-- Read-only actual-data preview for selective Retail/Backoffice cutover.
BEGIN;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260909163000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909163000';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260909162000')
    OR to_regclass('public.company_sales_process_settings') IS NULL
    OR to_regclass('public.sales_process_cutover_plans') IS NULL
    OR to_regprocedure('private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: cutover foundation incomplete';
  END IF;
  IF (SELECT count(*) FROM information_schema.tables
      WHERE table_schema='public' AND table_name IN(
        'company_features','pos_offline_sale_submissions','finance_posting_queue_runs',
        'sales_headers','sales_stock_reservations','sales_delivery_documents',
        'sales_dispatch_financial_effects','financial_events',
        'sales_payment_verification_requests','sales_payments','sales_invoice_snapshots',
        'sales_order_revisions','sales_order_procurement_demand_lines',
        'backoffice_sales_orders','backoffice_sales_reservations',
        'backoffice_sales_delivery_orders','backoffice_sales_delivery_receipts',
        'backoffice_sales_invoices'))<>18 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: preview source relation incomplete';
  END IF;
  IF to_regprocedure('private.get_sales_process_cutover_preview_core(uuid,text)') IS NOT NULL
    OR to_regprocedure('public.get_sales_process_cutover_preview(text)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: preview routine collision';
  END IF;
END
$guard$;

CREATE FUNCTION private.get_sales_process_cutover_preview_core(
  p_company_id uuid,p_target_mode text
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_setting public.company_sales_process_settings%rowtype;
  v_candidates jsonb:='[]'::jsonb;v_candidate jsonb;v_classification jsonb;
  v_requirements jsonb;v_record record;v_convert bigint:=0;v_blocked bigint:=0;
  v_keep bigint:=0;v_final bigint:=0;v_target_open bigint:=0;
  v_offline bigint:=0;v_queue bigint:=0;v_office_feature boolean:=false;
  v_warnings jsonb:='[]'::jsonb;
BEGIN
  SELECT setting.* INTO STRICT v_setting FROM public.company_sales_process_settings setting
  WHERE setting.company_id=p_company_id;
  IF p_target_mode NOT IN('RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE')
    OR p_target_mode=v_setting.active_mode THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_TARGET_INVALID';
  END IF;
  SELECT EXISTS(SELECT 1 FROM public.company_features feature
    WHERE feature.company_id=p_company_id
      AND feature.feature_code='backoffice_delivered_qty_sales_enabled'
      AND feature.is_enabled) INTO v_office_feature;
  SELECT count(*) INTO v_offline FROM public.pos_offline_sale_submissions submission
  WHERE submission.company_id=p_company_id
    AND submission.status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION');
  SELECT count(*) INTO v_queue FROM public.finance_posting_queue_runs queue
  WHERE queue.company_id=p_company_id AND queue.status IN('PREVIEWED','APPROVED','PROCESSING');
  IF v_offline>0 THEN
    v_warnings:=v_warnings||jsonb_build_array('NONTERMINAL_OFFLINE_SUBMISSION_REVIEW_REQUIRED');
  END IF;
  IF v_queue>0 THEN
    v_warnings:=v_warnings||jsonb_build_array('ACTIVE_FINANCE_QUEUE_MUST_FINISH');
  END IF;
  IF p_target_mode='BACKOFFICE_DELIVERED_QTY_INVOICE' AND NOT v_office_feature THEN
    v_warnings:=v_warnings||jsonb_build_array('BACKOFFICE_ENTITLEMENT_ENABLEMENT_REQUIRED');
  END IF;
  IF v_setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE' THEN
    v_warnings:=v_warnings||jsonb_build_array(
      'KEEP_BACKOFFICE_ENTITLEMENT_FOR_HISTORICAL_COMPLETION');
  END IF;

  IF v_setting.active_mode='RETAIL_CONFIRM_INVOICE' THEN
    SELECT count(*) INTO v_final FROM public.sales_headers sale
    WHERE sale.company_id=p_company_id AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
      AND sale.order_runtime_status IN('DELIVERED','CANCELED','LEGACY_POSTED');
    SELECT count(*) INTO v_target_open FROM public.backoffice_sales_orders document
    WHERE document.company_id=p_company_id AND document.status IN('DRAFT','SENT','CONFIRMED')
      AND document.fulfillment_status NOT IN('COMPLETED','CANCELED');
    FOR v_record IN
      SELECT sale.id,sale.draft_no,sale.invoice_no,sale.order_runtime_status,
        sale.master_version,sale.order_timing_mode,sale.planned_order_date,
        EXISTS(SELECT 1 FROM public.sales_stock_reservations reservation
          WHERE reservation.company_id=sale.company_id AND reservation.sales_id=sale.id
            AND reservation.status IN('OPEN','PARTIALLY_DISPATCHED')) has_reservation,
        EXISTS(SELECT 1 FROM public.sales_stock_reservations reservation
          WHERE reservation.company_id=sale.company_id AND reservation.sales_id=sale.id
            AND reservation.total_dispatched_base_qty>0) OR EXISTS(
          SELECT 1 FROM public.sales_delivery_documents delivery
          WHERE delivery.company_id=sale.company_id AND delivery.sales_id=sale.id
            AND delivery.status IN('PARTIALLY_DISPATCHED','DISPATCHED','DELIVERED')) has_dispatch,
        EXISTS(SELECT 1 FROM public.sales_dispatch_financial_effects effect
          WHERE effect.company_id=sale.company_id AND effect.sales_id=sale.id) has_final_stock,
        EXISTS(SELECT 1 FROM public.financial_events event
          WHERE event.company_id=sale.company_id AND event.root_sales_id=sale.id
            AND event.status::text='POSTED') OR EXISTS(
          SELECT 1 FROM public.sales_dispatch_financial_effects effect
          JOIN public.financial_events event ON event.company_id=effect.company_id
            AND event.id=effect.financial_event_id
          WHERE effect.company_id=sale.company_id AND effect.sales_id=sale.id
            AND event.status::text='POSTED') has_posted_finance,
        EXISTS(SELECT 1 FROM public.sales_payments payment
          WHERE payment.company_id=sale.company_id AND payment.sales_id=sale.id
            AND NOT payment.is_reversal) OR EXISTS(
          SELECT 1 FROM public.sales_payment_verification_requests payment
          WHERE payment.company_id=sale.company_id AND payment.sales_id=sale.id
            AND payment.status IN('PENDING','VERIFIED')) has_payment,
        EXISTS(SELECT 1 FROM public.sales_invoice_snapshots invoice
          WHERE invoice.company_id=sale.company_id AND invoice.sales_id=sale.id) has_invoice,
        EXISTS(SELECT 1 FROM public.sales_order_revisions revision
          WHERE revision.company_id=sale.company_id AND revision.source_sales_id=sale.id
            AND revision.status='PENDING') has_revision,
        EXISTS(SELECT 1 FROM public.sales_order_procurement_demand_lines demand
          WHERE demand.company_id=sale.company_id AND demand.sales_id=sale.id
            AND demand.status IN('OPEN','REQUESTED','ORDERED','AMENDMENT_REQUIRED')) has_procurement,
        COALESCE((SELECT jsonb_build_object('revisionId',revision.id,
            'replacementSalesId',revision.replacement_sales_id,
            'replacementDocumentNo',COALESCE(replacement.draft_no,replacement.invoice_no),
            'replacementStatus',replacement.order_runtime_status,
            'replacementMasterVersion',replacement.master_version)
          FROM public.sales_order_revisions revision
          JOIN public.sales_headers replacement ON replacement.company_id=revision.company_id
            AND replacement.id=revision.replacement_sales_id
          WHERE revision.company_id=sale.company_id AND revision.source_sales_id=sale.id
            AND revision.status='PENDING' LIMIT 1),'null'::jsonb) revision_pair
      FROM public.sales_headers sale
      WHERE sale.company_id=p_company_id
        AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
        AND sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED','CONFIRMED','RESERVED',
          'PARTIALLY_DISPATCHED','DISPATCHED')
        AND NOT EXISTS(SELECT 1 FROM public.sales_order_revisions revision
          WHERE revision.company_id=sale.company_id
            AND revision.replacement_sales_id=sale.id AND revision.status='PENDING')
      ORDER BY sale.created_at,sale.id
    LOOP
      v_classification:=private.classify_sales_process_conversion_candidate(
        v_setting.active_mode,p_target_mode,false,v_record.has_dispatch,
        v_record.has_final_stock,v_record.has_posted_finance,v_record.has_payment,
        v_record.has_invoice,v_record.has_revision,v_record.has_procurement);
      v_requirements:=v_classification->'requirementCodes';
      IF v_classification->>'decision'='CONVERT' AND v_record.has_reservation THEN
        v_requirements:=v_requirements||jsonb_build_array('TRANSFER_RESERVATION_LINEAGE');
      END IF;
      v_candidate:=jsonb_build_object('sourceDocumentType','RETAIL_SALE',
        'sourceDocumentId',v_record.id,
        'sourceDocumentNo',COALESCE(v_record.draft_no,v_record.invoice_no),
        'sourceStatus',v_record.order_runtime_status,
        'sourceMasterVersion',v_record.master_version,
        'decision',v_classification->>'decision',
        'blockerCodes',v_classification->'blockerCodes',
        'requirementCodes',v_requirements,
        'facts',jsonb_build_object('orderTimingMode',v_record.order_timing_mode,
          'plannedOrderDate',v_record.planned_order_date,
          'hasReservation',v_record.has_reservation,'hasDispatch',v_record.has_dispatch,
          'hasFinalStockEffect',v_record.has_final_stock,
          'hasPostedFinance',v_record.has_posted_finance,
          'hasPaymentHistory',v_record.has_payment,'hasIssuedInvoice',v_record.has_invoice,
          'hasPendingRevision',v_record.has_revision,
          'hasOpenProcurement',v_record.has_procurement,
          'revisionPair',v_record.revision_pair));
      v_candidates:=v_candidates||jsonb_build_array(v_candidate);
      IF v_classification->>'decision'='CONVERT' THEN v_convert:=v_convert+1;
      ELSIF v_classification->>'decision'='BLOCKED' THEN v_blocked:=v_blocked+1;
      ELSE v_keep:=v_keep+1; END IF;
    END LOOP;
  ELSE
    SELECT count(*) INTO v_final FROM public.backoffice_sales_orders document
    WHERE document.company_id=p_company_id
      AND (document.status='CANCELED' OR document.fulfillment_status IN('COMPLETED','CANCELED'));
    SELECT count(*) INTO v_target_open FROM public.sales_headers sale
    WHERE sale.company_id=p_company_id AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
      AND sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED','CONFIRMED','RESERVED',
        'PARTIALLY_DISPATCHED','DISPATCHED');
    FOR v_record IN
      SELECT document.id,document.quotation_no,document.order_no,document.status,
        document.fulfillment_status,document.master_version,document.order_date,
        document.planned_delivery_date,
        EXISTS(SELECT 1 FROM public.backoffice_sales_reservations reservation
          WHERE reservation.company_id=document.company_id
            AND reservation.sales_order_id=document.id AND reservation.status<>'RELEASED') has_reservation,
        EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_orders delivery
          WHERE delivery.company_id=document.company_id AND delivery.sales_order_id=document.id
            AND (delivery.status IN('PARTIALLY_SHIPPED','IN_TRANSIT','COMPLETED')
              OR delivery.total_shipped_base_qty>0)) has_dispatch,
        EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_receipts receipt
          WHERE receipt.company_id=document.company_id AND receipt.sales_order_id=document.id)
          has_final_stock,
        EXISTS(SELECT 1 FROM public.backoffice_sales_invoices invoice
          WHERE invoice.company_id=document.company_id AND invoice.sales_order_id=document.id
            AND invoice.status IN('POSTED','REVERSED')) OR EXISTS(
          SELECT 1 FROM public.backoffice_sales_delivery_receipts receipt
          JOIN public.financial_events event ON event.company_id=receipt.company_id
            AND event.id=receipt.financial_event_id
          WHERE receipt.company_id=document.company_id AND receipt.sales_order_id=document.id
            AND event.status::text='POSTED') has_posted_finance,
        EXISTS(SELECT 1 FROM public.backoffice_sales_invoices invoice
          WHERE invoice.company_id=document.company_id AND invoice.sales_order_id=document.id
            AND invoice.status IN('DRAFT','POSTED','REVERSED')) has_invoice
      FROM public.backoffice_sales_orders document
      WHERE document.company_id=p_company_id
        AND document.sales_process_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
        AND document.status IN('DRAFT','SENT','CONFIRMED')
        AND document.fulfillment_status NOT IN('COMPLETED','CANCELED')
      ORDER BY document.created_at,document.id
    LOOP
      v_classification:=private.classify_sales_process_conversion_candidate(
        v_setting.active_mode,p_target_mode,false,v_record.has_dispatch,
        v_record.has_final_stock,v_record.has_posted_finance,false,
        v_record.has_invoice,false,false);
      v_requirements:=v_classification->'requirementCodes';
      IF v_classification->>'decision'='CONVERT' AND v_record.has_reservation THEN
        v_requirements:=v_requirements||jsonb_build_array(
          'TRANSFER_RESERVATION_LINEAGE','RECONCILE_TARGET_PROCUREMENT_DEMAND');
      END IF;
      v_candidate:=jsonb_build_object('sourceDocumentType','BACKOFFICE_SALES_ORDER',
        'sourceDocumentId',v_record.id,
        'sourceDocumentNo',COALESCE(v_record.order_no,v_record.quotation_no),
        'sourceStatus',v_record.fulfillment_status,
        'sourceMasterVersion',v_record.master_version,
        'decision',v_classification->>'decision',
        'blockerCodes',v_classification->'blockerCodes',
        'requirementCodes',v_requirements,
        'facts',jsonb_build_object('documentStatus',v_record.status,
          'orderDate',v_record.order_date,'plannedDeliveryDate',v_record.planned_delivery_date,
          'hasReservation',v_record.has_reservation,'hasDispatch',v_record.has_dispatch,
          'hasFinalStockEffect',v_record.has_final_stock,
          'hasPostedFinance',v_record.has_posted_finance,
          'hasIssuedInvoice',v_record.has_invoice,
          'paymentRuntimeState','NOT_IMPLEMENTED_FOR_BACKOFFICE'));
      v_candidates:=v_candidates||jsonb_build_array(v_candidate);
      IF v_classification->>'decision'='CONVERT' THEN v_convert:=v_convert+1;
      ELSIF v_classification->>'decision'='BLOCKED' THEN v_blocked:=v_blocked+1;
      ELSE v_keep:=v_keep+1; END IF;
    END LOOP;
  END IF;
  RETURN jsonb_build_object('companyId',p_company_id,'currentMode',v_setting.active_mode,
    'targetMode',p_target_mode,'settingsVersion',v_setting.master_version,
    'modeEffectiveAt',v_setting.mode_effective_at,
    'officeEntitlementEnabled',v_office_feature,
    'summary',jsonb_build_object('convertible',v_convert,'blocked',v_blocked,
      'keepSource',v_keep,'finalSourceDocuments',v_final,
      'existingTargetOpenDocuments',v_target_open,
      'nonterminalOfflineSubmissions',v_offline,'activeFinanceQueues',v_queue),
    'warnings',v_warnings,'candidates',v_candidates,
    'readOnly',true,'previewVersion',1);
END
$$;

CREATE FUNCTION public.get_sales_process_cutover_preview(p_target_mode text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_actor uuid:=auth.uid();v_company uuid;v_role text;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT profile.role::text INTO v_role FROM public.profiles profile WHERE profile.id=v_actor;
  IF v_role IS DISTINCT FROM 'super_admin' THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_SUPER_ADMIN_REQUIRED';
  END IF;
  v_company:=public.private_active_company_id();
  RETURN private.get_sales_process_cutover_preview_core(v_company,p_target_mode);
END
$$;

REVOKE ALL ON FUNCTION private.get_sales_process_cutover_preview_core(uuid,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.get_sales_process_cutover_preview_core(uuid,text)
TO service_role;
REVOKE ALL ON FUNCTION public.get_sales_process_cutover_preview(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_sales_process_cutover_preview(text)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909163000','sales_process_cutover_preview_runtime',
  'Add Super-Admin actual-data read-only Retail/Backoffice cutover preview with revision-pair, Reservation, Procurement, Dispatch, Stock, Invoice, Payment, Finance, Offline and entitlement classification; no plan, switch or operational mutation');

COMMIT;
