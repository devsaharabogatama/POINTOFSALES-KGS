-- Retail POS nominal Product discounts become per-unit by Product policy.
-- Lettuce/Bawang Bombay retain whole-line semantics. Backoffice is unchanged.

BEGIN;

DO $guard$
BEGIN
  IF EXISTS(
    SELECT 1 FROM (
      VALUES
        ('20260721180000'),('20260729070000'),('20260730010000'),
        ('20260825120000'),('20260909140000'),('20260909162000'),
        ('20261031110000'),('20261102150000')
    ) required(version)
    WHERE NOT EXISTS(
      SELECT 1 FROM private.kgs_schema_migrations migration
      WHERE migration.version=required.version
    )
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: required ledger chain';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20261102160000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF EXISTS(SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='products'
      AND column_name='pos_line_discount_amount_basis')
    OR EXISTS(SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='sales_details'
        AND column_name='line_discount_amount_basis')
    OR to_regprocedure(
      'private.reprice_pos_sale_draft_before_per_unit_discount(uuid,uuid,uuid,jsonb,timestamptz)'
    ) IS NOT NULL
    OR to_regprocedure(
      'public.get_pos_offline_catalog_snapshot_before_discount_basis(uuid)'
    ) IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: partial installation';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
END
$guard$;

LOCK TABLE public.products,public.sales_headers,public.sales_details
  IN SHARE ROW EXCLUSIVE MODE;

ALTER TABLE public.products
  ADD COLUMN pos_line_discount_amount_basis TEXT NOT NULL DEFAULT 'PER_UNIT',
  ADD CONSTRAINT products_pos_line_discount_amount_basis_check CHECK(
    pos_line_discount_amount_basis IN('PER_UNIT','LINE_TOTAL')
  );

-- Only exact, proven Product identities receive the exception. Missing Products
-- are not created and similarly named Products are not guessed.
UPDATE public.products product SET
  pos_line_discount_amount_basis='LINE_TOTAL',
  master_version=product.master_version+1,
  updated_at=clock_timestamp()
FROM public.company_sales_process_settings setting
WHERE setting.company_id=product.company_id
  AND setting.active_mode='RETAIL_CONFIRM_INVOICE'
  AND (
    (product.sku='L' AND product.name='Lettuce')
    OR (product.sku='BB' AND product.name='Bawang Bombay')
  );

ALTER TABLE public.sales_details
  ADD COLUMN line_discount_amount_basis TEXT NOT NULL DEFAULT 'LINE_TOTAL',
  ADD CONSTRAINT sales_details_line_discount_amount_basis_check CHECK(
    line_discount_amount_basis IN('PER_UNIT','LINE_TOTAL')
  );

-- All historical rows were priced when AMOUNT meant whole-line. The default
-- above intentionally preserves that immutable interpretation.

-- Freeze the meaning of every existing open Retail POS nominal-discount Draft
-- before the new client contract is enabled.
WITH rewritten AS (
  SELECT sale.company_id,sale.id,
    jsonb_agg(
      CASE
        WHEN line.value->>'lineDiscountType'='AMOUNT'
          AND COALESCE((line.value->>'lineDiscountInput')::numeric,0)>0
        THEN line.value||jsonb_build_object(
          'lineDiscountAmountBasis','LINE_TOTAL'
        )
        ELSE line.value
      END
      ORDER BY line.ordinality
    ) AS lines
  FROM public.sales_headers sale
  CROSS JOIN LATERAL jsonb_array_elements(
    COALESCE(sale.payload_snapshot->'lines','[]'::jsonb)
  ) WITH ORDINALITY line(value,ordinality)
  WHERE sale.document_status='DRAFT'
    AND sale.sales_origin='POS'
    AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
  GROUP BY sale.company_id,sale.id
)
UPDATE public.sales_headers sale SET
  payload_snapshot=jsonb_set(sale.payload_snapshot,'{lines}',rewritten.lines,TRUE),
  updated_at=clock_timestamp()
FROM rewritten
WHERE sale.company_id=rewritten.company_id AND sale.id=rewritten.id;

ALTER FUNCTION private.reprice_pos_sale_draft(
  UUID,UUID,UUID,JSONB,TIMESTAMPTZ
) RENAME TO reprice_pos_sale_draft_before_per_unit_discount;

CREATE FUNCTION private.reprice_pos_sale_draft(
  p_company_id UUID,p_sales_id UUID,p_actor_id UUID,p_payload JSONB,
  p_resolved_at TIMESTAMPTZ
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_sale public.sales_headers%ROWTYPE;
  v_active_mode TEXT;
  v_line JSONB;
  v_prior_line JSONB;
  v_line_key TEXT;
  v_product_uom_id UUID;
  v_quantity NUMERIC(24,6);
  v_input NUMERIC(20,6);
  v_product_basis TEXT;
  v_supplied_basis TEXT;
  v_prior_basis TEXT;
  v_has_prior_resolved BOOLEAN;
  v_effective_basis TEXT;
  v_calculation_lines JSONB:='[]'::jsonb;
  v_persisted_lines JSONB:='[]'::jsonb;
  v_calculation_payload JSONB;
  v_result JSONB;
BEGIN
  SELECT * INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=p_company_id AND sale.id=p_sales_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALE_DRAFT_NOT_FOUND'; END IF;
  v_has_prior_resolved:=COALESCE(v_sale.payload_snapshot ? 'serverResolvedAt',FALSE);

  SELECT setting.active_mode INTO v_active_mode
  FROM public.company_sales_process_settings setting
  WHERE setting.company_id=p_company_id;

  IF v_sale.sales_origin<>'POS'
     OR v_sale.sales_process_mode<>'RETAIL_CONFIRM_INVOICE'
     OR v_active_mode IS DISTINCT FROM 'RETAIL_CONFIRM_INVOICE' THEN
    RETURN private.reprice_pos_sale_draft_before_per_unit_discount(
      p_company_id,p_sales_id,p_actor_id,p_payload,p_resolved_at
    );
  END IF;

  IF jsonb_typeof(p_payload->'lines') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'SALE_LINES_ARRAY_REQUIRED';
  END IF;

  FOR v_line IN SELECT value FROM jsonb_array_elements(p_payload->'lines')
  LOOP
    IF v_line->>'lineDiscountType' IS DISTINCT FROM 'AMOUNT' THEN
      v_calculation_lines:=v_calculation_lines||jsonb_build_array(
        v_line-'lineDiscountAmountBasis'
      );
      v_persisted_lines:=v_persisted_lines||jsonb_build_array(
        v_line-'lineDiscountAmountBasis'
      );
      CONTINUE;
    END IF;

    BEGIN
      v_line_key:=btrim(v_line->>'lineKey');
      v_product_uom_id:=(v_line->>'productUomId')::uuid;
      v_quantity:=(v_line->>'quantity')::numeric;
      v_input:=COALESCE((v_line->>'lineDiscountInput')::numeric,0);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'INVALID_SALE_LINE';
    END;

    SELECT product.pos_line_discount_amount_basis INTO v_product_basis
    FROM public.product_uoms product_uom
    JOIN public.products product
      ON product.company_id=product_uom.company_id
     AND product.id=product_uom.product_id
    WHERE product_uom.company_id=p_company_id
      AND product_uom.id=v_product_uom_id
      AND product.is_active AND product_uom.is_active
      AND product_uom.sales_allowed;
    IF v_product_basis IS NULL THEN
      RAISE EXCEPTION 'ACTIVE_SALES_PRODUCT_UOM_NOT_FOUND';
    END IF;

    v_supplied_basis:=NULLIF(btrim(v_line->>'lineDiscountAmountBasis'),'');
    IF v_supplied_basis IS NOT NULL
       AND v_supplied_basis NOT IN('PER_UNIT','LINE_TOTAL') THEN
      RAISE EXCEPTION 'LINE_DISCOUNT_AMOUNT_BASIS_INVALID';
    END IF;

    v_prior_line:=NULL;
    v_prior_basis:=NULL;
    IF v_has_prior_resolved THEN
      SELECT prior.value INTO v_prior_line
      FROM jsonb_array_elements(
        COALESCE(v_sale.payload_snapshot->'lines','[]'::jsonb)
      ) prior
      WHERE prior.value->>'lineKey'=v_line_key
        AND prior.value->>'productUomId'=v_product_uom_id::text
      LIMIT 1;
      v_prior_basis:=NULLIF(btrim(v_prior_line->>'lineDiscountAmountBasis'),'');
    END IF;

    IF v_prior_basis IS NOT NULL THEN
      IF v_supplied_basis IS NOT NULL
         AND v_supplied_basis IS DISTINCT FROM v_prior_basis THEN
        RAISE EXCEPTION 'LINE_DISCOUNT_AMOUNT_BASIS_IMMUTABLE';
      END IF;
      v_effective_basis:=v_prior_basis;
    ELSIF v_supplied_basis IS NOT NULL THEN
      IF v_supplied_basis IS DISTINCT FROM v_product_basis THEN
        RAISE EXCEPTION 'LINE_DISCOUNT_AMOUNT_BASIS_MISMATCH';
      END IF;
      v_effective_basis:=v_supplied_basis;
    ELSE
      -- Compatibility for an old client still open during database-first
      -- rollout. Its Draft is immediately snapshotted and cannot later change.
      v_effective_basis:='LINE_TOTAL';
    END IF;

    v_persisted_lines:=v_persisted_lines||jsonb_build_array(
      v_line||jsonb_build_object(
        'lineDiscountAmountBasis',v_effective_basis
      )
    );
    v_calculation_lines:=v_calculation_lines||jsonb_build_array(
      v_line||jsonb_build_object(
        'lineDiscountAmountBasis',v_effective_basis,
        'lineDiscountInput',CASE WHEN v_effective_basis='PER_UNIT'
          THEN round(v_input*v_quantity,6) ELSE v_input END
      )
    );
  END LOOP;

  v_calculation_payload:=jsonb_set(
    p_payload,'{lines}',v_calculation_lines,TRUE
  );
  v_result:=private.reprice_pos_sale_draft_before_per_unit_discount(
    p_company_id,p_sales_id,p_actor_id,v_calculation_payload,p_resolved_at
  );

  FOR v_line IN SELECT value FROM jsonb_array_elements(v_persisted_lines)
  LOOP
    IF v_line->>'lineDiscountType'='AMOUNT' THEN
      UPDATE public.sales_details detail SET
        line_discount_input=(v_line->>'lineDiscountInput')::numeric,
        line_discount_amount_basis=v_line->>'lineDiscountAmountBasis'
      WHERE detail.company_id=p_company_id
        AND detail.sales_id=p_sales_id
        AND detail.client_line_key=v_line->>'lineKey';
      IF NOT FOUND THEN RAISE EXCEPTION 'SALE_LINE_SNAPSHOT_NOT_FOUND'; END IF;
    END IF;
  END LOOP;

  UPDATE public.sales_headers sale SET
    payload_snapshot=jsonb_set(
      sale.payload_snapshot,'{lines}',v_persisted_lines,TRUE
    )
  WHERE sale.company_id=p_company_id AND sale.id=p_sales_id;

  RETURN v_result;
END
$$;

ALTER FUNCTION public.get_pos_offline_catalog_snapshot(UUID)
  RENAME TO get_pos_offline_catalog_snapshot_before_discount_basis;

CREATE FUNCTION public.get_pos_offline_catalog_snapshot(
  p_cashier_session_id UUID
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_snapshot JSONB;
  v_product_uoms JSONB;
BEGIN
  v_snapshot:=public.get_pos_offline_catalog_snapshot_before_discount_basis(
    p_cashier_session_id
  );
  SELECT COALESCE(jsonb_agg(
    item.value||jsonb_build_object(
      'lineDiscountAmountBasis',product.pos_line_discount_amount_basis
    ) ORDER BY item.ordinality
  ),'[]'::jsonb) INTO v_product_uoms
  FROM jsonb_array_elements(v_snapshot->'productUoms')
    WITH ORDINALITY item(value,ordinality)
  JOIN public.products product
    ON product.company_id=(v_snapshot->>'companyId')::uuid
   AND product.id=(item.value->>'productId')::uuid;
  RETURN jsonb_set(v_snapshot,'{productUoms}',v_product_uoms,TRUE);
END
$$;

REVOKE ALL ON FUNCTION
  private.reprice_pos_sale_draft_before_per_unit_discount(
    UUID,UUID,UUID,JSONB,TIMESTAMPTZ),
  private.reprice_pos_sale_draft(UUID,UUID,UUID,JSONB,TIMESTAMPTZ)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.reprice_pos_sale_draft_before_per_unit_discount(
    UUID,UUID,UUID,JSONB,TIMESTAMPTZ),
  private.reprice_pos_sale_draft(UUID,UUID,UUID,JSONB,TIMESTAMPTZ)
TO service_role;

REVOKE ALL ON FUNCTION
  public.get_pos_offline_catalog_snapshot_before_discount_basis(UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  public.get_pos_offline_catalog_snapshot_before_discount_basis(UUID)
TO service_role;
REVOKE ALL ON FUNCTION public.get_pos_offline_catalog_snapshot(UUID)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_pos_offline_catalog_snapshot(UUID)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
  '20261102160000','pos_retail_per_unit_product_discount',
  'Adds server-authoritative per-unit nominal Product discount for direct Retail POS, preserves Lettuce/Bawang Bombay and legacy Draft whole-line semantics, and keeps Backoffice unchanged'
);

NOTIFY pgrst,'reload schema';
COMMIT;
