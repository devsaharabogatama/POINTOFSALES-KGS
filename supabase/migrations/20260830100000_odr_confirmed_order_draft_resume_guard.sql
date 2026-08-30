-- Keep confirmed/reserved ODR Orders out of the editable Draft runtime.
BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended(
  '20260830100000_odr_confirmed_order_draft_resume_guard',0));

DO $$
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260830100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828100000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828110000')
    OR to_regprocedure('public.save_pos_sale_draft(jsonb)') IS NULL
    OR to_regprocedure(
      'private.save_pos_sale_draft_before_schedule_core(jsonb)') IS NULL
    OR to_regprocedure('public.list_pos_sale_drafts(uuid)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR Draft and reservation runtime required';
  END IF;
  IF pg_get_functiondef(
      'private.save_pos_sale_draft_before_schedule_core(jsonb)'::regprocedure)
      !~'public.save_pos_sale_draft' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Draft save path drift';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.sales_headers sale
    JOIN public.sale_stock_requirements requirement
      ON requirement.company_id=sale.company_id AND requirement.sales_id=sale.id
    JOIN public.sales_stock_reservation_lines line
      ON line.company_id=requirement.company_id
     AND line.stock_requirement_id=requirement.id
    WHERE sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED')
      AND sale.confirmed_at IS NULL
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: input Draft owns reservation';
  END IF;
END
$$;

ALTER FUNCTION public.save_pos_sale_draft(JSONB)
  RENAME TO odr6e_save_pos_sale_draft_legacy;
ALTER FUNCTION public.odr6e_save_pos_sale_draft_legacy(JSONB)
  SET SCHEMA private;

CREATE FUNCTION public.save_pos_sale_draft(p_payload JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
  v_sales UUID;v_runtime_status TEXT;v_confirmed_at TIMESTAMPTZ;
BEGIN
  BEGIN
    v_sales:=NULLIF(p_payload->>'saleId','')::UUID;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'INVALID_SALE_IDENTITY';
  END;

  IF v_sales IS NOT NULL THEN
    SELECT sale.order_runtime_status,sale.confirmed_at
      INTO v_runtime_status,v_confirmed_at
    FROM public.sales_headers sale
    WHERE sale.company_id=v_company AND sale.id=v_sales
    FOR UPDATE;
    IF FOUND AND (v_confirmed_at IS NOT NULL
      OR v_runtime_status NOT IN('DRAFT_INPUT','SCHEDULED')) THEN
      RAISE EXCEPTION 'CONFIRMED_SALES_ORDER_IMMUTABLE';
    END IF;
    IF EXISTS(
      SELECT 1 FROM public.sale_stock_requirements requirement
      JOIN public.sales_stock_reservation_lines line
        ON line.company_id=requirement.company_id
       AND line.stock_requirement_id=requirement.id
      WHERE requirement.company_id=v_company
        AND requirement.sales_id=v_sales
    ) THEN
      RAISE EXCEPTION 'CONFIRMED_SALES_ORDER_IMMUTABLE';
    END IF;
  END IF;

  RETURN private.odr6e_save_pos_sale_draft_legacy(p_payload);
END
$$;

CREATE OR REPLACE FUNCTION public.list_pos_sale_drafts(p_store_id UUID DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_timezone TEXT;v_today DATE;
BEGIN
  SELECT company.timezone INTO v_timezone FROM public.companies company
  WHERE company.id=v_company;
  v_today:=(clock_timestamp() AT TIME ZONE v_timezone)::DATE;
  RETURN (SELECT COALESCE(jsonb_agg(item ORDER BY
      CASE WHEN operational_status='ACTIVE' THEN 1 ELSE 2 END,
      planned_date NULLS FIRST,updated_at DESC),'[]'::JSONB)
    FROM (SELECT sale.updated_at,sale.planned_order_date planned_date,
      CASE WHEN sale.order_timing_mode='SCHEDULED'
        AND sale.planned_order_date>v_today THEN 'SCHEDULED' ELSE 'ACTIVE' END operational_status,
      jsonb_build_object('salesId',sale.id,'draftNo',sale.draft_no,
        'draftLabel',sale.draft_label,'draftNotes',sale.draft_notes,
        'draftReason',sale.draft_reason,'customerId',sale.customer_id,
        'customerName',customer.name,'storeId',sale.store_id,'storeName',store.store_name,
        'createdBy',sale.created_by,'createdByName',creator.name,'createdAt',sale.created_at,
        'transactionAt',CASE WHEN sale.order_timing_mode='SCHEDULED'
          THEN COALESCE(sale.payload_snapshot->>'plannedOrderAt',sale.transaction_date::TEXT)
          ELSE sale.transaction_date::TEXT END,
        'transactionDateSource',sale.transaction_date_source,'updatedAt',sale.updated_at,
        'masterVersion',sale.master_version,'grandTotal',sale.grand_total_after_rounding,
        'lineCount',(SELECT count(*) FROM public.sales_details detail
          WHERE detail.company_id=sale.company_id AND detail.sales_id=sale.id),
        'isStale',sale.created_at<clock_timestamp()-interval '7 days',
        'orderTimingMode',sale.order_timing_mode,
        'plannedOrderDate',sale.planned_order_date,
        'operationalStatus',CASE WHEN sale.order_timing_mode='SCHEDULED'
          AND sale.planned_order_date>v_today THEN 'SCHEDULED' ELSE 'ACTIVE' END,
        'canPost',NOT(sale.order_timing_mode='SCHEDULED'
          AND sale.planned_order_date>v_today),
        'orderRuntimeStatus',sale.order_runtime_status,
        'lockOwnerId',sale.edit_lock_owner_id,'lockOwnerName',lock_owner.name,
        'lockSessionId',sale.edit_lock_session_id,
        'lockHeartbeatAt',sale.edit_lock_heartbeat_at,
        'lockExpired',sale.edit_lock_heartbeat_at IS NOT NULL AND
          sale.edit_lock_heartbeat_at<clock_timestamp()-interval '5 minutes',
        'payloadSnapshot',sale.payload_snapshot) item
      FROM public.sales_headers sale
      JOIN public.customers customer ON customer.company_id=sale.company_id
       AND customer.id=sale.customer_id
      JOIN public.stores store ON store.company_id=sale.company_id AND store.id=sale.store_id
      JOIN public.profiles creator ON creator.id=sale.created_by
      LEFT JOIN public.profiles lock_owner ON lock_owner.id=sale.edit_lock_owner_id
      WHERE sale.company_id=v_company AND sale.document_status='DRAFT'
        AND sale.confirmed_at IS NULL
        AND sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED')
        AND (p_store_id IS NULL OR sale.store_id=p_store_id)
        AND (public.private_user_has_any_company_role(sale.company_id,
          ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[])
          OR public.private_user_has_any_store_role(sale.store_id,
          ARRAY['CASHIER','STORE_MANAGER']::TEXT[]))) visible);
END
$$;

REVOKE ALL ON FUNCTION private.odr6e_save_pos_sale_draft_legacy(JSONB)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.odr6e_save_pos_sale_draft_legacy(JSONB)
TO service_role;
REVOKE ALL ON FUNCTION public.save_pos_sale_draft(JSONB),
  public.list_pos_sale_drafts(UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_pos_sale_draft(JSONB),
  public.list_pos_sale_drafts(UUID) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260830100000','odr_confirmed_order_draft_resume_guard',
  'Exclude confirmed/reserved ODR Orders from editable Draft list and fail before repricing can delete reservation-referenced stock requirements');

NOTIFY pgrst,'reload schema';
COMMIT;
