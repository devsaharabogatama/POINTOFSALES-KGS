-- Preserve the one-absolute-due-date contract across Retail/Backoffice cutover
-- and fail closed when an open Backoffice document has multiple installments.
-- This migration does not apply a cutover or mutate an operational document.
BEGIN;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260910152000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260910152000';
  END IF;
  IF (SELECT count(*) FROM private.kgs_schema_migrations WHERE version IN(
      '20260909156000','20260909157000','20260909162000','20260909163000',
      '20260910110000','20260910120000','20260910130000','20260910140000',
      '20260910150000','20260910151000'))<>10
    OR to_regprocedure('private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)') IS NULL
    OR to_regprocedure('private.get_sales_process_cutover_preview_core(uuid,text)') IS NULL
    OR to_regclass('public.backoffice_sales_payment_term_lines') IS NULL
    OR to_regclass('public.backoffice_sales_invoice_receivable_schedules') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Payment Term cutover dependency incomplete';
  END IF;
  IF to_regprocedure('private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Payment Term classifier overload collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_process_cutover_plans
      WHERE status IN('DRAFT','PREVIEWED','APPLYING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: cancel open cutover plan and recreate after Payment Term classifier upgrade';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
END
$guard$;

CREATE FUNCTION private.classify_sales_process_conversion_candidate(
  p_source_mode text,p_target_mode text,p_is_final boolean,
  p_has_dispatch boolean,p_has_final_stock_effect boolean,
  p_has_posted_finance boolean,p_has_nonterminal_payment boolean,
  p_has_issued_invoice boolean,p_has_pending_revision boolean,
  p_has_open_procurement boolean,p_has_multi_installment boolean
) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path=public,pg_temp AS $$
DECLARE v_result jsonb;
BEGIN
  v_result:=private.classify_sales_process_conversion_candidate(
    p_source_mode,p_target_mode,p_is_final,p_has_dispatch,
    p_has_final_stock_effect,p_has_posted_finance,p_has_nonterminal_payment,
    p_has_issued_invoice,p_has_pending_revision,p_has_open_procurement);

  IF NOT p_is_final
    AND p_source_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
    AND p_target_mode='RETAIL_CONFIRM_INVOICE'
    AND p_has_multi_installment THEN
    v_result:=jsonb_build_object('decision','BLOCKED',
      'blockerCodes',CASE WHEN v_result->'blockerCodes' ? 'MULTI_INSTALLMENT_MUST_FINISH_IN_BACKOFFICE'
        THEN v_result->'blockerCodes'
        ELSE (v_result->'blockerCodes')||jsonb_build_array('MULTI_INSTALLMENT_MUST_FINISH_IN_BACKOFFICE') END,
      'requirementCodes','[]'::jsonb);
  END IF;
  RETURN v_result;
END
$$;

REVOKE ALL ON FUNCTION
  private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)
TO service_role;

CREATE OR REPLACE FUNCTION private.get_sales_process_cutover_preview_core(
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
        sale.is_tempo,sale.due_date,
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
        v_record.has_invoice,v_record.has_revision,v_record.has_procurement,false);
      v_requirements:=v_classification->'requirementCodes';
      IF v_classification->>'decision'='CONVERT' AND v_record.has_reservation THEN
        v_requirements:=v_requirements||jsonb_build_array('TRANSFER_RESERVATION_LINEAGE');
      END IF;
      IF v_classification->>'decision'='CONVERT' AND v_record.is_tempo THEN
        v_requirements:=v_requirements||jsonb_build_array('PRESERVE_SINGLE_ABSOLUTE_DUE_DATE');
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
          'isTempo',v_record.is_tempo,'legacyDueDate',v_record.due_date,
          'paymentTermShape','SINGLE_ABSOLUTE_DUE_DATE',
          'hasMultiInstallmentPaymentTerm',false,
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
        document.planned_delivery_date,document.is_tempo,document.due_date,
        COALESCE((SELECT count(*) FROM public.backoffice_sales_payment_term_lines line
          WHERE line.company_id=document.company_id
            AND line.payment_term_id=document.payment_term_id),0)::bigint header_term_lines,
        COALESCE((SELECT max(schedule_count) FROM (
          SELECT count(schedule.id)::bigint schedule_count
          FROM public.backoffice_sales_invoices invoice
          LEFT JOIN public.backoffice_sales_invoice_receivable_schedules schedule
            ON schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id
          WHERE invoice.company_id=document.company_id
            AND invoice.sales_order_id=document.id AND invoice.status='DRAFT'
          GROUP BY invoice.id) counted),0)::bigint draft_schedule_max,
        COALESCE((SELECT max(term_line_count) FROM (
          SELECT count(term_line.id)::bigint term_line_count
          FROM public.backoffice_sales_invoices invoice
          LEFT JOIN public.backoffice_sales_payment_term_lines term_line
            ON term_line.company_id=invoice.company_id
           AND term_line.payment_term_id=invoice.payment_term_id
          WHERE invoice.company_id=document.company_id
            AND invoice.sales_order_id=document.id AND invoice.status='DRAFT'
          GROUP BY invoice.id) counted),0)::bigint draft_invoice_term_line_max,
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
        v_record.has_invoice,false,false,
        greatest(v_record.header_term_lines,v_record.draft_schedule_max,
          v_record.draft_invoice_term_line_max)>1);
      v_requirements:=v_classification->'requirementCodes';
      IF v_classification->>'decision'='CONVERT' AND v_record.has_reservation THEN
        v_requirements:=v_requirements||jsonb_build_array(
          'TRANSFER_RESERVATION_LINEAGE','RECONCILE_TARGET_PROCUREMENT_DEMAND');
      END IF;
      IF v_classification->>'decision'='CONVERT' AND v_record.is_tempo THEN
        v_requirements:=v_requirements||jsonb_build_array('PRESERVE_SINGLE_ABSOLUTE_DUE_DATE');
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
          'isTempo',v_record.is_tempo,'legacyDueDate',v_record.due_date,
          'paymentTermShape',CASE WHEN greatest(v_record.header_term_lines,
              v_record.draft_schedule_max,v_record.draft_invoice_term_line_max)>1
            THEN 'MULTI_INSTALLMENT' ELSE 'SINGLE_ABSOLUTE_DUE_DATE' END,
          'headerPaymentTermLineCount',v_record.header_term_lines,
          'draftInvoicePaymentTermLineMax',v_record.draft_invoice_term_line_max,
          'draftInvoiceScheduleLineMax',v_record.draft_schedule_max,
          'hasMultiInstallmentPaymentTerm',greatest(v_record.header_term_lines,
            v_record.draft_schedule_max,v_record.draft_invoice_term_line_max)>1,
          'hasReservation',v_record.has_reservation,'hasDispatch',v_record.has_dispatch,
          'hasFinalStockEffect',v_record.has_final_stock,
          'hasPostedFinance',v_record.has_posted_finance,
          'hasIssuedInvoice',v_record.has_invoice,
          'paymentRuntimeState','DRAFT_SCHEDULE_INSPECTED'));
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
    'readOnly',true,'previewVersion',2);
END
$$;

REVOKE ALL ON FUNCTION private.get_sales_process_cutover_preview_core(uuid,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.get_sales_process_cutover_preview_core(uuid,text)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260910152000','sales_process_cutover_payment_term_boundary',
  'Upgrade read-only cutover preview to preserve one absolute due date and block Office-to-Retail conversion when an open SO or Draft Invoice has multiple Payment Term schedules; retain the legacy classifier signature and make no operational or mode mutation');

COMMIT;

