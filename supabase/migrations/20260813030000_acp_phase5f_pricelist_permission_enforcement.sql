-- ACP-5F: enforce Pricelist management without widening POS or Customer access.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813020000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-5E required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813030000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
    WHERE permission_key='sales.pricelists'
      AND enforcement_status='SHADOW')<>1 THEN
    RAISE EXCEPTION 'PRICELIST_PERMISSION_NOT_SHADOW';
  END IF;
  IF EXISTS(SELECT 1 FROM public.companies company
    WHERE company.status='ACTIVE' AND (SELECT count(*)
      FROM public.pricelists pricelist
      WHERE pricelist.company_id=company.id AND pricelist.scope='GLOBAL'
        AND pricelist.is_active AND pricelist.is_default)<>1) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Global Pricelist required';
  END IF;
END
$guard$;

CREATE FUNCTION public.get_sales_pricelists(
  p_include_inactive BOOLEAN DEFAULT FALSE
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.pricelists','VIEW');
  RETURN jsonb_build_object(
    'companyId',v_company,
    'data',(SELECT COALESCE(jsonb_agg(
      to_jsonb(pricelist_row)||jsonb_build_object(
        'store_assignments',COALESCE((SELECT jsonb_agg(jsonb_build_object(
          'id',assignment.id,'pricelist_id',assignment.pricelist_id,
          'store_id',assignment.store_id) ORDER BY assignment.store_id)
          FROM public.pricelist_store_assignments assignment
          WHERE assignment.company_id=v_company
            AND assignment.pricelist_id=pricelist_row.id),'[]'::JSONB),
        'rules',COALESCE((SELECT jsonb_agg(jsonb_build_object(
          'id',rule.id,'pricelist_id',rule.pricelist_id,
          'product_id',rule.product_id,'product_uom_id',rule.product_uom_id,
          'min_qty',rule.min_qty,'tier_qty_basis',rule.tier_qty_basis,
          'pricing_method',rule.pricing_method,
          'fixed_unit_price',rule.fixed_unit_price,
          'discount_amount_per_unit',rule.discount_amount_per_unit,
          'discount_percent',rule.discount_percent,
          'valid_from',rule.valid_from,'valid_until',rule.valid_until,
          'is_active',rule.is_active,'rule_version',rule.rule_version,
          'master_version',rule.master_version)
          ORDER BY rule.min_qty DESC,rule.id)
          FROM public.pricelist_rules rule
          WHERE rule.company_id=v_company
            AND rule.pricelist_id=pricelist_row.id AND rule.is_active),
          '[]'::JSONB))
      ORDER BY pricelist_row.priority DESC,pricelist_row.name,pricelist_row.id),
      '[]'::JSONB)
      FROM (SELECT pricelist.id,pricelist.company_id,pricelist.code,
        pricelist.name,pricelist.scope,pricelist.customer_id,
        pricelist.priority,pricelist.is_default,
        pricelist.applies_all_stores,pricelist.valid_from,
        pricelist.valid_until,pricelist.is_active,pricelist.notes,
        pricelist.master_version,pricelist.created_at,pricelist.updated_at
      FROM public.pricelists pricelist
      WHERE pricelist.company_id=v_company
        AND (COALESCE(p_include_inactive,FALSE) OR pricelist.is_active)
      ORDER BY pricelist.priority DESC,pricelist.name,pricelist.id
      LIMIT 300) pricelist_row),
    'stores',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',store.id,'store_code',store.store_code,
      'store_name',store.store_name,'status',store.status)
      ORDER BY store.store_name,store.id),'[]'::JSONB)
      FROM public.stores store WHERE store.company_id=v_company
        AND store.status='ACTIVE'));
END
$$;

CREATE FUNCTION public.get_pos_pricelist_references(p_store_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.cashier_sessions session
    WHERE session.company_id=v_company AND session.cashier_id=v_actor
      AND session.store_id=p_store_id
      AND session.status='OPEN'::public.session_status) THEN
    RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED';
  END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'id',pricelist.id,'name',pricelist.name,'scope',pricelist.scope,
    'is_default',pricelist.is_default,
    'applies_all_stores',pricelist.applies_all_stores,
    'valid_from',pricelist.valid_from,'valid_until',pricelist.valid_until)
    ORDER BY pricelist.priority DESC,pricelist.name,pricelist.id)
    FROM public.pricelists pricelist
    WHERE pricelist.company_id=v_company AND pricelist.is_active
      AND (pricelist.applies_all_stores OR EXISTS(
        SELECT 1 FROM public.pricelist_store_assignments assignment
        WHERE assignment.company_id=v_company
          AND assignment.pricelist_id=pricelist.id
          AND assignment.store_id=p_store_id))),'[]'::JSONB);
END
$$;

CREATE FUNCTION public.export_sales_pricelists()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.pricelists','EXPORT');
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'pricelistName',pricelist.name,'scope',pricelist.scope,
    'priority',pricelist.priority,'isDefault',pricelist.is_default,
    'storeScope',CASE WHEN pricelist.applies_all_stores THEN 'SEMUA TOKO'
      ELSE COALESCE((SELECT string_agg(store.store_name,', ' ORDER BY store.store_name)
        FROM public.pricelist_store_assignments assignment
        JOIN public.stores store ON store.company_id=assignment.company_id
          AND store.id=assignment.store_id
        WHERE assignment.company_id=v_company
          AND assignment.pricelist_id=pricelist.id),'') END,
    'validFrom',pricelist.valid_from,'validUntil',pricelist.valid_until,
    'isActive',pricelist.is_active,'productName',product.name,
    'uomName',uom.name,'minimumQty',rule.min_qty,
    'quantityBasis',rule.tier_qty_basis,'pricingMethod',rule.pricing_method,
    'finalUnitPrice',rule.fixed_unit_price,
    'discountAmountPerUnit',rule.discount_amount_per_unit,
    'discountPercent',rule.discount_percent,'ruleActive',rule.is_active)
    ORDER BY pricelist.name,product.name,uom.name,rule.min_qty DESC)
    FROM public.pricelists pricelist
    LEFT JOIN public.pricelist_rules rule
      ON rule.company_id=pricelist.company_id
     AND rule.pricelist_id=pricelist.id
    LEFT JOIN public.products product ON product.company_id=rule.company_id
      AND product.id=rule.product_id
    LEFT JOIN public.product_uoms product_uom
      ON product_uom.company_id=rule.company_id
     AND product_uom.id=rule.product_uom_id
    LEFT JOIN public.uoms uom ON uom.company_id=product_uom.company_id
      AND uom.id=product_uom.uom_id
    WHERE pricelist.company_id=v_company),'[]'::JSONB);
END
$$;

ALTER FUNCTION public.save_reusable_pricelist_with_rules(
  UUID,BIGINT,TEXT,TEXT,INTEGER,BOOLEAN,BOOLEAN,UUID[],
  TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN,TEXT,JSONB)
  RENAME TO acp5f_save_reusable_pricelist_with_rules_core;
ALTER FUNCTION public.acp5f_save_reusable_pricelist_with_rules_core(
  UUID,BIGINT,TEXT,TEXT,INTEGER,BOOLEAN,BOOLEAN,UUID[],
  TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN,TEXT,JSONB) SET SCHEMA private;

CREATE FUNCTION public.save_reusable_pricelist_with_rules(
  p_pricelist_id UUID,p_master_version BIGINT,p_name TEXT,p_scope TEXT,
  p_priority INTEGER,p_is_default BOOLEAN,p_applies_all_stores BOOLEAN,
  p_store_ids UUID[],p_valid_from TIMESTAMPTZ,p_valid_until TIMESTAMPTZ,
  p_is_active BOOLEAN,p_notes TEXT,p_rules JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.pricelists','MANAGE');
  RETURN private.acp5f_save_reusable_pricelist_with_rules_core(
    p_pricelist_id,p_master_version,p_name,p_scope,p_priority,p_is_default,
    p_applies_all_stores,p_store_ids,p_valid_from,p_valid_until,p_is_active,
    p_notes,p_rules);
END
$$;

DO $enforce$
DECLARE v_rows BIGINT;
BEGIN
  UPDATE public.access_permission_catalog SET
    enforcement_status='ENFORCED',catalog_version=catalog_version+1,
    updated_at=clock_timestamp()
  WHERE permission_key='sales.pricelists' AND enforcement_status='SHADOW';
  GET DIAGNOSTICS v_rows=ROW_COUNT;
  IF v_rows<>1 THEN RAISE EXCEPTION 'PRICELIST_PERMISSION_CUTOVER_FAILED'; END IF;
END
$enforce$;

REVOKE SELECT ON public.pricelists,public.pricelist_store_assignments,
  public.pricelist_rules,public.pricelist_master_audit FROM authenticated;

REVOKE ALL ON FUNCTION
  private.acp5f_save_reusable_pricelist_with_rules_core(
    UUID,BIGINT,TEXT,TEXT,INTEGER,BOOLEAN,BOOLEAN,UUID[],
    TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN,TEXT,JSONB)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.acp5f_save_reusable_pricelist_with_rules_core(
    UUID,BIGINT,TEXT,TEXT,INTEGER,BOOLEAN,BOOLEAN,UUID[],
    TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN,TEXT,JSONB)
TO service_role;

-- The code-bearing overload is an internal compatibility target used by the
-- automatic-code wrapper. It must never remain browser executable.
REVOKE ALL ON FUNCTION public.save_reusable_pricelist_with_rules(
  UUID,BIGINT,TEXT,TEXT,TEXT,INTEGER,BOOLEAN,BOOLEAN,UUID[],
  TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN,TEXT,JSONB)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.save_reusable_pricelist_with_rules(
  UUID,BIGINT,TEXT,TEXT,TEXT,INTEGER,BOOLEAN,BOOLEAN,UUID[],
  TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN,TEXT,JSONB)
TO service_role;

REVOKE ALL ON FUNCTION public.get_sales_pricelists(BOOLEAN),
  public.get_pos_pricelist_references(UUID),public.export_sales_pricelists(),
  public.save_reusable_pricelist_with_rules(
    UUID,BIGINT,TEXT,TEXT,INTEGER,BOOLEAN,BOOLEAN,UUID[],
    TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN,TEXT,JSONB)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_sales_pricelists(BOOLEAN),
  public.get_pos_pricelist_references(UUID),public.export_sales_pricelists(),
  public.save_reusable_pricelist_with_rules(
    UUID,BIGINT,TEXT,TEXT,INTEGER,BOOLEAN,BOOLEAN,UUID[],
    TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN,TEXT,JSONB)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260813030000','acp_phase5f_pricelist_permission_enforcement',
  'Enforced Pricelist VIEW/MANAGE/EXPORT with independent POS and Offline pricing authority');

COMMIT;
