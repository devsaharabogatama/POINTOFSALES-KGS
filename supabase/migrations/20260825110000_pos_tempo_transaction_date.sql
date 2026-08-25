-- POS TEMPO transaction date and due-date suggestion support.
-- Additive response fields only; Sale posting semantics remain unchanged.
BEGIN;

DO $migration_guard$
BEGIN
  IF EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260825110000'
  ) THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
END
$migration_guard$;

CREATE OR REPLACE FUNCTION public.get_pos_customer_references()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_actor UUID:=auth.uid();
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM public.cashier_sessions session
    WHERE session.company_id=v_company
      AND session.cashier_id=v_actor
      AND session.status='OPEN'::public.session_status
  ) THEN
    RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED';
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id',customer.id,
      'code',customer.code,
      'name',customer.name,
      'phone',customer.phone,
      'address',customer.address,
      'is_system_customer',customer.is_system_customer,
      'is_active',customer.is_active,
      'default_pricelist_id',customer.default_pricelist_id,
      'current_balance',customer.current_balance,
      'credit_limit',customer.credit_limit,
      'credit_term_days',customer.credit_term_days
    ) ORDER BY customer.is_system_customer DESC,customer.name,customer.id)
    FROM public.customers customer
    WHERE customer.company_id=v_company AND customer.is_active
  ),'[]'::JSONB);
END
$$;

CREATE OR REPLACE FUNCTION public.save_pos_sale_draft_with_pricelist(
  p_payload JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_result JSONB;
  v_transaction_at TIMESTAMPTZ;
BEGIN
  PERFORM set_config(
    'kgs.selected_pricelist_id',
    COALESCE(NULLIF(p_payload->>'selectedPricelistId',''),''),
    TRUE
  );
  v_result:=public.save_pos_sale_draft(p_payload);

  SELECT sale.transaction_date INTO v_transaction_at
  FROM public.sales_headers sale
  WHERE sale.company_id=public.private_active_company_id()
    AND sale.id=(v_result->>'salesId')::UUID;
  IF v_transaction_at IS NULL THEN
    RAISE EXCEPTION 'SALE_DRAFT_TRANSACTION_DATE_NOT_FOUND';
  END IF;

  RETURN v_result||jsonb_build_object('transactionAt',v_transaction_at);
END
$$;

CREATE OR REPLACE FUNCTION public.list_pos_sale_drafts(
  p_store_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
  SELECT COALESCE(jsonb_agg(item ORDER BY updated_at DESC),'[]'::jsonb)
  FROM (
    SELECT sale.updated_at,jsonb_build_object(
      'salesId',sale.id,
      'draftNo',sale.draft_no,
      'draftLabel',sale.draft_label,
      'draftNotes',sale.draft_notes,
      'draftReason',sale.draft_reason,
      'customerId',sale.customer_id,
      'customerName',customer.name,
      'storeId',sale.store_id,
      'storeName',store.store_name,
      'createdBy',sale.created_by,
      'createdByName',creator.name,
      'createdAt',sale.created_at,
      'transactionAt',sale.transaction_date,
      'updatedAt',sale.updated_at,
      'masterVersion',sale.master_version,
      'grandTotal',sale.grand_total_after_rounding,
      'lineCount',(
        SELECT count(*) FROM public.sales_details detail
        WHERE detail.company_id=sale.company_id AND detail.sales_id=sale.id
      ),
      'isStale',sale.created_at<clock_timestamp()-interval '7 days',
      'lockOwnerId',sale.edit_lock_owner_id,
      'lockOwnerName',lock_owner.name,
      'lockSessionId',sale.edit_lock_session_id,
      'lockHeartbeatAt',sale.edit_lock_heartbeat_at,
      'lockExpired',sale.edit_lock_heartbeat_at IS NOT NULL
        AND sale.edit_lock_heartbeat_at<clock_timestamp()-interval '5 minutes',
      'payloadSnapshot',sale.payload_snapshot
    ) AS item
    FROM public.sales_headers sale
    JOIN public.customers customer
      ON customer.company_id=sale.company_id AND customer.id=sale.customer_id
    JOIN public.stores store
      ON store.company_id=sale.company_id AND store.id=sale.store_id
    JOIN public.profiles creator ON creator.id=sale.created_by
    LEFT JOIN public.profiles lock_owner ON lock_owner.id=sale.edit_lock_owner_id
    WHERE sale.company_id=public.private_active_company_id()
      AND sale.document_status='DRAFT'
      AND (p_store_id IS NULL OR sale.store_id=p_store_id)
      AND (
        public.private_user_has_any_company_role(
          sale.company_id,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
        )
        OR public.private_user_has_any_store_role(
          sale.store_id,ARRAY['CASHIER','STORE_MANAGER']::TEXT[]
        )
      )
  ) visible;
$$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
  '20260825110000','pos_tempo_transaction_date',
  'Returns canonical Sale transaction time and Customer credit term to POS so TEMPO order and due dates can be shown without client-authoritative transaction timestamps'
);

COMMIT;
