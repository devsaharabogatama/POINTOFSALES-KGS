-- Allow a system WALK-IN Customer only for fully allocated Backoffice Invoice
-- receipts. Retail allocations, unapplied receipts and Customer Balance remain
-- governed by their existing non-system Customer boundary.
BEGIN;

DO $guard$
DECLARE v_definition text;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
    WHERE version IN('20260911160000','20260911161000','20260911162000','20260912138000'))<>4 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Invoice payment chain incomplete';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912139000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260912139000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  SELECT pg_get_functiondef(to_regprocedure(
    'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)'))
  INTO STRICT v_definition;
  IF v_definition NOT LIKE '%AND customer.id=p_customer_id AND customer.is_active AND NOT customer.is_system_customer FOR SHARE;%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Receipt customer guard drift';
  END IF;
END
$guard$;

DO $patch$
DECLARE v_definition text;v_old text;v_new text;v_occurrences integer;
BEGIN
  SELECT pg_get_functiondef(to_regprocedure(
    'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)'))
  INTO STRICT v_definition;
  v_old:=$old$AND customer.id=p_customer_id AND customer.is_active AND NOT customer.is_system_customer FOR SHARE;$old$;
  v_new:=$new$AND customer.id=p_customer_id AND customer.is_active
    AND (NOT customer.is_system_customer OR (
      customer.is_system_customer
      -- BACKOFFICE_SYSTEM_CUSTOMER_ALLOCATED_ONLY
      AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(p_allocations) system_allocation(item)
        WHERE upper(btrim(COALESCE(system_allocation.item->>'sourceType','')))
          <>'BACKOFFICE_SALES_INVOICE')
    )) FOR SHARE;$new$;
  v_occurrences:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_occurrences<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Receipt guard occurrence drift';
  END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$patch$;

REVOKE ALL ON FUNCTION
  public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)
  TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260912139000','backoffice_sales_system_customer_payment_fix',
  'Permit active system WALK-IN Customer only for fully allocated Backoffice Invoice receipts; preserve Retail, unapplied receipt and Customer Balance non-system boundaries');

NOTIFY pgrst,'reload schema';
COMMIT;
