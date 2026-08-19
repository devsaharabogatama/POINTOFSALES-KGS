-- PRD: guarded UOM and Product Category cleanup before UAT.
-- Adds hard delete only for unreferenced masters and locks UOM semantics after use.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260812140000'
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-4B required';
  END IF;
  IF EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260818090000'
  ) THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
END
$guard$;

ALTER TABLE public.inventory_master_write_audit
  DROP CONSTRAINT inventory_master_audit_action_check;
ALTER TABLE public.inventory_master_write_audit
  ADD CONSTRAINT inventory_master_audit_action_check
  CHECK(action IN('CREATE','UPDATE','DELETE'));

CREATE FUNCTION private.trg_prd_guard_used_uom_semantics()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
BEGIN
  IF ROW(OLD.uom_type,OLD.allow_decimal,OLD.decimal_precision)
     IS DISTINCT FROM
     ROW(NEW.uom_type,NEW.allow_decimal,NEW.decimal_precision)
     AND (
       EXISTS(
         SELECT 1 FROM public.products product
         WHERE product.company_id=OLD.company_id
           AND (product.uom_id=OLD.id OR product.weight_reference_uom_id=OLD.id)
       )
       OR EXISTS(
         SELECT 1 FROM public.product_uoms product_uom
         WHERE product_uom.company_id=OLD.company_id
           AND product_uom.uom_id=OLD.id
       )
       OR EXISTS(
         SELECT 1 FROM public.product_uom_conversions conversion_row
         WHERE conversion_row.company_id=OLD.company_id
           AND (conversion_row.from_uom_id=OLD.id OR conversion_row.to_uom_id=OLD.id)
       )
     ) THEN
    RAISE EXCEPTION 'UOM_SEMANTICS_LOCKED_BY_USAGE';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_prd_guard_used_uom_semantics
BEFORE UPDATE OF uom_type,allow_decimal,decimal_precision
ON public.uoms
FOR EACH ROW
EXECUTE FUNCTION private.trg_prd_guard_used_uom_semantics();

CREATE FUNCTION public.delete_inventory_uom(
  p_uom_id UUID,
  p_expected_version BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_actor UUID;
  v_current public.uoms%ROWTYPE;
  v_prior_delete public.inventory_master_write_audit%ROWTYPE;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.master_data','MANAGE'
  );
  v_actor:=private.acp_require_inventory_master_actor(v_company);
  IF p_uom_id IS NULL OR p_expected_version IS NULL OR p_expected_version<1 THEN
    RAISE EXCEPTION 'MASTER_VERSION_REQUIRED';
  END IF;

  SELECT * INTO v_current
  FROM public.uoms
  WHERE company_id=v_company AND id=p_uom_id
  FOR UPDATE;

  IF NOT FOUND THEN
    SELECT * INTO v_prior_delete
    FROM public.inventory_master_write_audit audit
    WHERE audit.company_id=v_company
      AND audit.master_type='UOM'
      AND audit.master_id=p_uom_id
      AND audit.action='DELETE'
      AND audit.actor_id=v_actor
    ORDER BY audit.id DESC
    LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object(
        'success',TRUE,'action','EXACT_RETRY','data',v_prior_delete.before_state
      );
    END IF;
    RAISE EXCEPTION 'MASTER_NOT_FOUND';
  END IF;

  IF p_expected_version IS DISTINCT FROM v_current.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;

  -- Legacy conversions use ON DELETE CASCADE. Check canonical and legacy
  -- references explicitly so a cleanup action can never erase a conversion.
  IF EXISTS(
      SELECT 1 FROM public.products product
      WHERE product.company_id=v_company
        AND (product.uom_id=p_uom_id OR product.weight_reference_uom_id=p_uom_id)
    ) OR EXISTS(
      SELECT 1 FROM public.product_uoms product_uom
      WHERE product_uom.company_id=v_company AND product_uom.uom_id=p_uom_id
    ) OR EXISTS(
      SELECT 1 FROM public.product_uom_conversions conversion_row
      WHERE conversion_row.company_id=v_company
        AND (conversion_row.from_uom_id=p_uom_id OR conversion_row.to_uom_id=p_uom_id)
    ) THEN
    RAISE EXCEPTION 'UOM_IN_USE';
  END IF;

  BEGIN
    DELETE FROM public.uoms
    WHERE company_id=v_company AND id=p_uom_id;
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE EXCEPTION 'UOM_IN_USE';
  END;

  INSERT INTO public.inventory_master_write_audit(
    company_id,master_type,master_id,actor_id,action,before_state,after_state
  ) VALUES(
    v_company,'UOM',v_current.id,v_actor,'DELETE',to_jsonb(v_current),
    jsonb_build_object('deleted',TRUE,'id',v_current.id)
  );

  RETURN jsonb_build_object(
    'success',TRUE,'action','DELETE','data',to_jsonb(v_current)
  );
END;
$$;

CREATE FUNCTION public.delete_inventory_product_category(
  p_category_id UUID,
  p_expected_version BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_actor UUID;
  v_current public.product_categories%ROWTYPE;
  v_prior_delete public.inventory_master_write_audit%ROWTYPE;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.master_data','MANAGE'
  );
  v_actor:=private.acp_require_inventory_master_actor(v_company);
  IF p_category_id IS NULL OR p_expected_version IS NULL OR p_expected_version<1 THEN
    RAISE EXCEPTION 'MASTER_VERSION_REQUIRED';
  END IF;

  SELECT * INTO v_current
  FROM public.product_categories
  WHERE company_id=v_company AND id=p_category_id
  FOR UPDATE;

  IF NOT FOUND THEN
    SELECT * INTO v_prior_delete
    FROM public.inventory_master_write_audit audit
    WHERE audit.company_id=v_company
      AND audit.master_type='PRODUCT_CATEGORY'
      AND audit.master_id=p_category_id
      AND audit.action='DELETE'
      AND audit.actor_id=v_actor
    ORDER BY audit.id DESC
    LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object(
        'success',TRUE,'action','EXACT_RETRY','data',v_prior_delete.before_state
      );
    END IF;
    RAISE EXCEPTION 'MASTER_NOT_FOUND';
  END IF;

  IF p_expected_version IS DISTINCT FROM v_current.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;

  BEGIN
    DELETE FROM public.product_categories
    WHERE company_id=v_company AND id=p_category_id;
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE EXCEPTION 'PRODUCT_CATEGORY_IN_USE';
  END;

  INSERT INTO public.inventory_master_write_audit(
    company_id,master_type,master_id,actor_id,action,before_state,after_state
  ) VALUES(
    v_company,'PRODUCT_CATEGORY',v_current.id,v_actor,'DELETE',to_jsonb(v_current),
    jsonb_build_object('deleted',TRUE,'id',v_current.id)
  );

  RETURN jsonb_build_object(
    'success',TRUE,'action','DELETE','data',to_jsonb(v_current)
  );
END;
$$;

REVOKE ALL ON FUNCTION
  private.trg_prd_guard_used_uom_semantics(),
  public.delete_inventory_uom(UUID,BIGINT),
  public.delete_inventory_product_category(UUID,BIGINT)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION private.trg_prd_guard_used_uom_semantics()
FROM authenticated;
GRANT EXECUTE ON FUNCTION
  public.delete_inventory_uom(UUID,BIGINT),
  public.delete_inventory_product_category(UUID,BIGINT)
TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION private.trg_prd_guard_used_uom_semantics()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
  '20260818090000',
  'prd_guarded_inventory_master_cleanup',
  'Guarded audited delete for unused UOM/Product Category and semantic lock after UOM use'
);

COMMIT;
