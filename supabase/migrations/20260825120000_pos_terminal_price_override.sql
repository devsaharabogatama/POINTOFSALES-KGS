-- POS Terminal price override: server-authoritative online Sale line override.
-- Default remains OFF for every existing and future Terminal.
BEGIN;

DO $guard$
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260825100000','20260825110000'))<>2 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: POS price preview and TEMPO transaction date required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260825120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF to_regprocedure('private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamptz)') IS NULL
     OR to_regprocedure('private.reprice_pos_sale_draft(uuid,uuid,uuid,jsonb,timestamptz)') IS NULL
     OR to_regprocedure('public.save_pos_terminal_ui_settings(uuid,bigint,text[])') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical POS runtime missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline Sale exists';
  END IF;
END
$guard$;

ALTER TABLE public.pos_terminals
  ADD COLUMN allow_price_override BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE public.sales_details
  ADD COLUMN canonical_resolved_unit_price NUMERIC(20,4),
  ADD COLUMN price_override_applied BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN price_override_unit_price NUMERIC(20,4),
  ADD COLUMN price_override_actor_id UUID,
  ADD COLUMN price_override_terminal_id UUID,
  ADD COLUMN price_override_session_id UUID,
  ADD COLUMN price_override_source TEXT,
  ADD COLUMN price_override_resolved_at TIMESTAMPTZ;

UPDATE public.sales_details
SET canonical_resolved_unit_price=resolved_unit_price
WHERE canonical_resolved_unit_price IS NULL;

ALTER TABLE public.sales_details
  ALTER COLUMN canonical_resolved_unit_price SET DEFAULT 0,
  ALTER COLUMN canonical_resolved_unit_price SET NOT NULL,
  ADD CONSTRAINT sales_details_canonical_price_nonnegative CHECK(
    canonical_resolved_unit_price>=0
  ),
  ADD CONSTRAINT sales_details_price_override_shape CHECK(
    (
      NOT price_override_applied
      AND price_override_unit_price IS NULL
      AND price_override_actor_id IS NULL
      AND price_override_terminal_id IS NULL
      AND price_override_session_id IS NULL
      AND price_override_source IS NULL
      AND price_override_resolved_at IS NULL
    ) OR (
      price_override_applied
      AND price_override_unit_price IS NOT NULL
      AND price_override_unit_price>=0
      AND price_override_unit_price=resolved_unit_price
      AND price_override_actor_id IS NOT NULL
      AND price_override_terminal_id IS NOT NULL
      AND price_override_session_id IS NOT NULL
      AND price_override_source='CASHIER_INPUT'
      AND price_override_resolved_at IS NOT NULL
    )
  ),
  ADD CONSTRAINT sales_details_price_override_actor_fk
    FOREIGN KEY(price_override_actor_id) REFERENCES public.profiles(id) ON DELETE RESTRICT,
  ADD CONSTRAINT sales_details_price_override_terminal_fk
    FOREIGN KEY(company_id,price_override_terminal_id)
    REFERENCES public.pos_terminals(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT sales_details_price_override_session_fk
    FOREIGN KEY(company_id,price_override_session_id)
    REFERENCES public.cashier_sessions(company_id,id) ON DELETE RESTRICT;

CREATE INDEX idx_sales_details_company_price_override
  ON public.sales_details(company_id,sales_id)
  WHERE price_override_applied;

ALTER FUNCTION private.resolve_pos_sale_price(
  UUID,UUID,UUID,UUID,NUMERIC,TIMESTAMPTZ
) RENAME TO resolve_pos_sale_price_before_terminal_override;

CREATE FUNCTION private.resolve_pos_sale_price(
  p_company_id UUID,p_store_id UUID,p_customer_id UUID,p_product_uom_id UUID,
  p_quantity NUMERIC,p_resolved_at TIMESTAMPTZ
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_result JSONB;
  v_map_raw TEXT:=NULLIF(current_setting('kgs.pos_price_override_map',TRUE),'');
  v_map JSONB:='{}'::JSONB;
  v_override NUMERIC(20,4);
BEGIN
  IF v_map_raw IS NOT NULL THEN
    BEGIN v_map:=v_map_raw::JSONB;
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'INVALID_POS_PRICE_OVERRIDE_CONTEXT';
    END;
    IF jsonb_typeof(v_map)<>'object' THEN
      RAISE EXCEPTION 'INVALID_POS_PRICE_OVERRIDE_CONTEXT';
    END IF;
    -- Reject the override before entering the Offline snapshot resolver. This
    -- guarantees a stable, explicit boundary even when an Offline submission
    -- id is present in the transaction-local context.
    IF v_map ? p_product_uom_id::TEXT
       AND NULLIF(current_setting('kgs.offline_submission_id',TRUE),'') IS NOT NULL THEN
      RAISE EXCEPTION 'OFFLINE_PRICE_OVERRIDE_NOT_ALLOWED';
    END IF;
  END IF;

  v_result:=private.resolve_pos_sale_price_before_terminal_override(
    p_company_id,p_store_id,p_customer_id,p_product_uom_id,p_quantity,p_resolved_at
  );
  IF v_map_raw IS NULL OR NOT v_map ? p_product_uom_id::TEXT THEN
    RETURN v_result||jsonb_build_object(
      'canonicalResolvedUnitPrice',(v_result->>'resolvedUnitPrice')::NUMERIC,
      'priceOverrideApplied',FALSE
    );
  END IF;
  BEGIN
    v_override:=round((v_map->>p_product_uom_id::TEXT)::NUMERIC,4);
  EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'INVALID_POS_PRICE_OVERRIDE_AMOUNT';
  END;
  IF v_override IS NULL OR v_override<0 OR v_override>999999999999999.9999 THEN
    RAISE EXCEPTION 'INVALID_POS_PRICE_OVERRIDE_AMOUNT';
  END IF;
  RETURN v_result||jsonb_build_object(
    'canonicalResolvedUnitPrice',(v_result->>'resolvedUnitPrice')::NUMERIC,
    'resolvedUnitPrice',v_override,
    'priceOverrideApplied',TRUE,
    'priceOverrideSource','CASHIER_INPUT'
  );
END
$$;

ALTER FUNCTION private.reprice_pos_sale_draft(
  UUID,UUID,UUID,JSONB,TIMESTAMPTZ
) RENAME TO reprice_pos_sale_draft_before_terminal_override;

CREATE FUNCTION private.reprice_pos_sale_draft(
  p_company_id UUID,p_sales_id UUID,p_actor_id UUID,p_payload JSONB,
  p_resolved_at TIMESTAMPTZ
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_sale public.sales_headers%ROWTYPE;
  v_line JSONB;v_product_uom_id UUID;v_override NUMERIC(20,4);
  v_override_map JSONB:='{}'::JSONB;v_override_count INTEGER:=0;
  v_result JSONB;v_canonical JSONB;
BEGIN
  SELECT * INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=p_company_id AND sale.id=p_sales_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALE_DRAFT_NOT_FOUND'; END IF;
  IF jsonb_typeof(p_payload->'lines') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'SALE_LINES_ARRAY_REQUIRED';
  END IF;

  FOR v_line IN SELECT value FROM jsonb_array_elements(p_payload->'lines')
  LOOP
    IF v_line ? 'overrideUnitPrice'
       AND jsonb_typeof(v_line->'overrideUnitPrice')<>'null' THEN
      BEGIN
        v_product_uom_id:=(v_line->>'productUomId')::UUID;
        v_override:=round((v_line->>'overrideUnitPrice')::NUMERIC,4);
      EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'INVALID_POS_PRICE_OVERRIDE_AMOUNT';
      END;
      IF v_override IS NULL OR v_override<0 OR v_override>999999999999999.9999 THEN
        RAISE EXCEPTION 'INVALID_POS_PRICE_OVERRIDE_AMOUNT';
      END IF;
      IF v_override_map ? v_product_uom_id::TEXT THEN
        RAISE EXCEPTION 'DUPLICATE_POS_PRICE_OVERRIDE_PRODUCT_UOM';
      END IF;
      v_override_map:=v_override_map||jsonb_build_object(
        v_product_uom_id::TEXT,v_override
      );
      v_override_count:=v_override_count+1;
    END IF;
  END LOOP;

  IF v_override_count>0 THEN
    IF COALESCE(v_sale.source_channel,'ONLINE')<>'ONLINE' THEN
      RAISE EXCEPTION 'OFFLINE_PRICE_OVERRIDE_NOT_ALLOWED';
    END IF;
    IF NOT EXISTS(
      SELECT 1 FROM public.pos_terminals terminal
      JOIN public.cashier_sessions session
        ON session.company_id=terminal.company_id
       AND session.pos_id=terminal.id
       AND session.id=v_sale.session_id
      WHERE terminal.company_id=p_company_id
       AND terminal.id=v_sale.pos_id
       AND terminal.store_id=v_sale.store_id
       AND terminal.status='ACTIVE'
       AND terminal.allow_price_override
       AND session.status='OPEN'::public.session_status
       AND session.cashier_id=p_actor_id
    ) THEN
      RAISE EXCEPTION 'POS_TERMINAL_PRICE_OVERRIDE_DISABLED';
    END IF;
  END IF;

  PERFORM set_config('kgs.pos_price_override_map',v_override_map::TEXT,TRUE);
  v_result:=private.reprice_pos_sale_draft_before_terminal_override(
    p_company_id,p_sales_id,p_actor_id,p_payload,p_resolved_at
  );

  -- Store the canonical Pricelist result independently from the final price.
  FOR v_line IN SELECT value FROM jsonb_array_elements(p_payload->'lines')
  LOOP
    v_product_uom_id:=(v_line->>'productUomId')::UUID;
    SELECT private.resolve_pos_sale_price_before_terminal_override(
      p_company_id,v_sale.store_id,v_sale.customer_id,v_product_uom_id,
      (v_line->>'quantity')::NUMERIC,p_resolved_at
    ) INTO v_canonical;
    UPDATE public.sales_details detail SET
      canonical_resolved_unit_price=(v_canonical->>'resolvedUnitPrice')::NUMERIC,
      price_override_applied=(v_override_map ? v_product_uom_id::TEXT),
      price_override_unit_price=CASE WHEN v_override_map ? v_product_uom_id::TEXT
        THEN (v_override_map->>v_product_uom_id::TEXT)::NUMERIC END,
      price_override_actor_id=CASE WHEN v_override_map ? v_product_uom_id::TEXT
        THEN p_actor_id END,
      price_override_terminal_id=CASE WHEN v_override_map ? v_product_uom_id::TEXT
        THEN v_sale.pos_id END,
      price_override_session_id=CASE WHEN v_override_map ? v_product_uom_id::TEXT
        THEN v_sale.session_id END,
      price_override_source=CASE WHEN v_override_map ? v_product_uom_id::TEXT
        THEN 'CASHIER_INPUT' END,
      price_override_resolved_at=CASE WHEN v_override_map ? v_product_uom_id::TEXT
        THEN p_resolved_at END
    WHERE detail.company_id=p_company_id AND detail.sales_id=p_sales_id
      AND detail.client_line_key=btrim(v_line->>'lineKey')
      AND detail.product_uom_id=v_product_uom_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'PRICE_OVERRIDE_LINE_SNAPSHOT_NOT_FOUND'; END IF;
  END LOOP;
  PERFORM set_config('kgs.pos_price_override_map','{}',TRUE);
  RETURN v_result||jsonb_build_object('priceOverrideLineCount',v_override_count);
END
$$;

CREATE OR REPLACE FUNCTION public.get_pos_terminal_ui_settings()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.pos_terminals terminal
    WHERE terminal.company_id=v_company
      AND private.mads_can_manage_terminal_ui(v_actor,v_company,terminal.store_id)) THEN
    RAISE EXCEPTION 'TERMINAL_UI_SETTINGS_ACCESS_DENIED';
  END IF;
  RETURN jsonb_build_object('companyId',v_company,'terminals',COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'terminalId',terminal.id,'terminalCode',terminal.pos_code,
      'terminalName',terminal.pos_name,'terminalStatus',terminal.status,
      'storeId',terminal.store_id,'storeName',store.store_name,
      'hiddenFeatureKeys',to_jsonb(terminal.hidden_feature_keys),
      'allowPriceOverride',terminal.allow_price_override,
      'masterVersion',terminal.ui_settings_master_version,
      'updatedAt',terminal.ui_settings_updated_at)
      ORDER BY store.store_name,terminal.pos_name,terminal.id)
    FROM public.pos_terminals terminal
    JOIN public.stores store ON store.company_id=terminal.company_id
      AND store.id=terminal.store_id
    WHERE terminal.company_id=v_company
      AND private.mads_can_manage_terminal_ui(v_actor,v_company,terminal.store_id)
  ),'[]'::JSONB));
END
$$;

CREATE FUNCTION public.save_pos_terminal_ui_settings(
  p_terminal_id UUID,p_expected_version BIGINT,p_hidden_feature_keys TEXT[],
  p_allow_price_override BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_terminal public.pos_terminals%ROWTYPE;v_hidden TEXT[];v_next BIGINT;
  v_allow BOOLEAN:=COALESCE(p_allow_price_override,FALSE);
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT ARRAY(SELECT DISTINCT upper(btrim(value))
    FROM unnest(COALESCE(p_hidden_feature_keys,'{}'::TEXT[])) value
    WHERE btrim(value)<>'' ORDER BY 1) INTO v_hidden;
  IF NOT v_hidden<@ARRAY['SALES_RETURN','EXPENSE','STOCK_REQUEST','GOODS_RECEIPT',
    'PURCHASE_RETURN','CASH_DEPOSIT','OFFLINE']::TEXT[] THEN
    RAISE EXCEPTION 'INVALID_POS_TERMINAL_UI_FEATURE';
  END IF;
  SELECT * INTO v_terminal FROM public.pos_terminals terminal
  WHERE terminal.company_id=v_company AND terminal.id=p_terminal_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'POS_TERMINAL_NOT_FOUND'; END IF;
  IF NOT private.mads_can_manage_terminal_ui(v_actor,v_company,v_terminal.store_id) THEN
    RAISE EXCEPTION 'TERMINAL_UI_SETTINGS_ACCESS_DENIED';
  END IF;
  IF v_terminal.hidden_feature_keys=v_hidden
     AND v_terminal.allow_price_override=v_allow THEN
    RETURN jsonb_build_object('success',TRUE,'action','EXACT_RETRY',
      'terminalId',v_terminal.id,'hiddenFeatureKeys',to_jsonb(v_hidden),
      'allowPriceOverride',v_allow,'masterVersion',v_terminal.ui_settings_master_version);
  END IF;
  IF p_expected_version IS DISTINCT FROM v_terminal.ui_settings_master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  v_next:=v_terminal.ui_settings_master_version+1;
  UPDATE public.pos_terminals SET hidden_feature_keys=v_hidden,
    allow_price_override=v_allow,ui_settings_master_version=v_next,
    ui_settings_updated_at=clock_timestamp(),ui_settings_updated_by=v_actor
  WHERE id=v_terminal.id;
  INSERT INTO public.pos_terminal_ui_setting_audit(
    company_id,terminal_id,action,before_state,after_state,actor_id
  ) VALUES(v_company,v_terminal.id,'UPDATE',jsonb_build_object(
      'hiddenFeatureKeys',to_jsonb(v_terminal.hidden_feature_keys),
      'allowPriceOverride',v_terminal.allow_price_override,
      'masterVersion',v_terminal.ui_settings_master_version),jsonb_build_object(
      'hiddenFeatureKeys',to_jsonb(v_hidden),'allowPriceOverride',v_allow,
      'masterVersion',v_next),v_actor);
  RETURN jsonb_build_object('success',TRUE,'action','UPDATE',
    'terminalId',v_terminal.id,'hiddenFeatureKeys',to_jsonb(v_hidden),
    'allowPriceOverride',v_allow,'masterVersion',v_next);
END
$$;

CREATE OR REPLACE FUNCTION public.save_pos_terminal_ui_settings(
  p_terminal_id UUID,p_expected_version BIGINT,p_hidden_feature_keys TEXT[]
) RETURNS JSONB LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT public.save_pos_terminal_ui_settings(
    p_terminal_id,p_expected_version,p_hidden_feature_keys,
    COALESCE((SELECT terminal.allow_price_override
      FROM public.pos_terminals terminal
      WHERE terminal.company_id=public.private_active_company_id()
        AND terminal.id=p_terminal_id),FALSE)
  )
$$;

REVOKE UPDATE(allow_price_override) ON public.pos_terminals FROM authenticated;
REVOKE ALL ON FUNCTION
  private.resolve_pos_sale_price_before_terminal_override(
    UUID,UUID,UUID,UUID,NUMERIC,TIMESTAMPTZ),
  private.resolve_pos_sale_price(UUID,UUID,UUID,UUID,NUMERIC,TIMESTAMPTZ),
  private.reprice_pos_sale_draft_before_terminal_override(
    UUID,UUID,UUID,JSONB,TIMESTAMPTZ),
  private.reprice_pos_sale_draft(UUID,UUID,UUID,JSONB,TIMESTAMPTZ)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.resolve_pos_sale_price_before_terminal_override(
    UUID,UUID,UUID,UUID,NUMERIC,TIMESTAMPTZ),
  private.resolve_pos_sale_price(UUID,UUID,UUID,UUID,NUMERIC,TIMESTAMPTZ),
  private.reprice_pos_sale_draft_before_terminal_override(
    UUID,UUID,UUID,JSONB,TIMESTAMPTZ),
  private.reprice_pos_sale_draft(UUID,UUID,UUID,JSONB,TIMESTAMPTZ)
TO service_role;
REVOKE ALL ON FUNCTION public.save_pos_terminal_ui_settings(
  UUID,BIGINT,TEXT[],BOOLEAN) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_pos_terminal_ui_settings(
  UUID,BIGINT,TEXT[],BOOLEAN) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260825120000','pos_terminal_price_override',
  'Adds default-OFF audited Terminal price override, canonical versus final Sale line snapshots, server-side online Save/Post enforcement, and preserves Offline denial');
NOTIFY pgrst,'reload schema';
COMMIT;
