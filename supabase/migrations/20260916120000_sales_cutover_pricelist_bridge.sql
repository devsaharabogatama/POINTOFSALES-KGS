-- Forward fix: preserve one Retail Pricelist while the Backoffice Draft bridge
-- performs its canonical validation. Final target values remain source-owned.
BEGIN;

DO $guard$
DECLARE
  v_definition text;
  v_declaration text:='  v_pricelist uuid;v_pricelist_count bigint;';
  v_payload_marker text:=$m$    'dueDate',v_due_date,'currencyCode','IDR','selectedPricelistId',NULL,$m$;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260916100000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: 20260916100000 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260916120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260916120000';
  END IF;
  IF to_regprocedure('private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)') IS NULL
    OR to_regprocedure('public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical converter call chain missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;

  v_definition:=replace(pg_get_functiondef(
    'private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)'::regprocedure),
    chr(13)||chr(10),chr(10));
  IF (length(v_definition)-length(replace(v_definition,v_declaration,'')))
      /length(v_declaration)<>1
    OR (length(v_definition)-length(replace(v_definition,v_payload_marker,'')))
      /length(v_payload_marker)<>1
    OR (length(v_definition)-length(replace(v_definition,
      'v_payload:=jsonb_build_object(','')))
      /length('v_payload:=jsonb_build_object(')<>1
    OR position('pricelist_id=v_pricelist,' IN v_definition)=0
    OR position('COALESCE(to_jsonb(request_line),''null''::jsonb)' IN v_definition)=0
    OR position('COALESCE(to_jsonb(request_document),''null''::jsonb)' IN v_definition)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Retail converter runtime drift';
  END IF;
END
$guard$;

DO $patch$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
BEGIN
  v_definition:=replace(pg_get_functiondef(
    'private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)'::regprocedure),
    chr(13)||chr(10),chr(10));

  v_old:='  v_pricelist uuid;v_pricelist_count bigint;';
  v_new:='  v_pricelist uuid;v_pricelist_count bigint;v_save_pricelist uuid;v_pricing_at timestamptz;';
  IF (length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: converter declaration anchor drift';
  END IF;
  v_definition:=replace(v_definition,v_old,v_new);

  v_old:='v_payload:=jsonb_build_object(';
  v_new:=$m$-- The source mixed-Pricelist rejection immediately above remains
  -- authoritative. This block only supplies one provisional construction
  -- Pricelist to the canonical Backoffice Draft writer.
  -- Save Draft is only a validated construction bridge. Force one eligible
  -- Pricelist across every provisional line so its AUTO resolver cannot mix
  -- line-level Pricelists. The source Pricelist/snapshot is restored below.
  v_pricing_at:=(v_order_date+time '12:00') AT TIME ZONE v_timezone;
  SELECT pricelist.id INTO v_save_pricelist
  FROM public.pricelists pricelist
  LEFT JOIN public.customers customer
    ON customer.company_id=pricelist.company_id AND customer.id=v_source.customer_id
  WHERE pricelist.company_id=p_company_id AND pricelist.id=v_pricelist
    AND pricelist.is_active
    AND (pricelist.valid_from IS NULL OR pricelist.valid_from<=v_pricing_at)
    AND (pricelist.valid_until IS NULL OR pricelist.valid_until>=v_pricing_at)
    AND (pricelist.scope='GLOBAL'
      OR (pricelist.scope='CUSTOMER' AND customer.default_pricelist_id=pricelist.id))
    AND (pricelist.applies_all_stores OR EXISTS(
      SELECT 1 FROM public.pricelist_store_assignments assignment
      WHERE assignment.company_id=pricelist.company_id
        AND assignment.pricelist_id=pricelist.id
        AND assignment.store_id=v_source.store_id));

  IF v_save_pricelist IS NULL THEN
    SELECT pricelist.id INTO v_save_pricelist
    FROM public.pricelists pricelist
    LEFT JOIN public.customers customer
      ON customer.company_id=pricelist.company_id AND customer.id=v_source.customer_id
    WHERE pricelist.company_id=p_company_id AND pricelist.is_active
      AND (pricelist.valid_from IS NULL OR pricelist.valid_from<=v_pricing_at)
      AND (pricelist.valid_until IS NULL OR pricelist.valid_until>=v_pricing_at)
      AND ((pricelist.scope='CUSTOMER' AND customer.default_pricelist_id=pricelist.id)
        OR (pricelist.scope='GLOBAL' AND pricelist.is_default))
      AND (pricelist.applies_all_stores OR EXISTS(
        SELECT 1 FROM public.pricelist_store_assignments assignment
        WHERE assignment.company_id=pricelist.company_id
          AND assignment.pricelist_id=pricelist.id
          AND assignment.store_id=v_source.store_id))
    ORDER BY CASE WHEN pricelist.scope='CUSTOMER' THEN 0 ELSE 1 END,
      pricelist.priority DESC,pricelist.id
    LIMIT 1;
  END IF;

  v_payload:=jsonb_build_object($m$;
  IF (length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: converter payload-start anchor drift';
  END IF;
  v_definition:=replace(v_definition,v_old,v_new);

  v_old:=$m$    'dueDate',v_due_date,'currencyCode','IDR','selectedPricelistId',NULL,$m$;
  v_new:=$m$    'dueDate',v_due_date,'currencyCode','IDR','selectedPricelistId',v_save_pricelist,$m$;
  IF (length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: converter payload anchor drift';
  END IF;
  v_definition:=replace(v_definition,v_old,v_new);
  EXECUTE v_definition;
END
$patch$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260916120000','sales_cutover_pricelist_bridge',
  'Forward fix Retail-to-Office conversion: use one eligible provisional Pricelist during canonical Draft construction, then preserve exact source header/line Pricelist and commercial snapshots; no backfill or operational data mutation');

NOTIFY pgrst,'reload schema';
COMMIT;
