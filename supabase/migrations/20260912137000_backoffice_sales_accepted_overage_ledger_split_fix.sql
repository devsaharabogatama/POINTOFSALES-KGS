-- Forward-fix: accepted overage is a separate Invoice source and must not also
-- increase the regular Sales Order accepted quantity ledger.
BEGIN;

LOCK TABLE public.backoffice_sales_order_lines IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.backoffice_sales_delivery_discrepancy_lines IN SHARE ROW EXCLUSIVE MODE;

DO $guard$
DECLARE v_definition text;v_constraint text;v_legacy_count integer;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
    WHERE version IN('20260912123000','20260912124000','20260912125000',
      '20260912130000','20260912132000','20260912136000'))<>6 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: accepted-overage dependency chain incomplete';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912137000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260912137000';
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
    'private.resolve_backoffice_sales_overage_wrong_item_core(uuid,bigint,uuid,date,text)'))
  INTO v_definition;
  IF v_definition IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: accepted-overage resolver missing';
  END IF;
  v_legacy_count:=(length(v_definition)-length(replace(v_definition,
    'accepted_base_qty=accepted_base_qty+v_qty,updated_at=v_now','')))
    /length('accepted_base_qty=accepted_base_qty+v_qty,updated_at=v_now');
  IF v_legacy_count<>1
    OR position('approved_overage_base_qty=approved_overage_base_qty+v_qty' in v_definition)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: accepted-overage resolver anchor drift';
  END IF;
  SELECT pg_get_constraintdef(constraint_state.oid) INTO v_constraint
  FROM pg_constraint constraint_state
  WHERE constraint_state.conrelid='public.backoffice_sales_order_lines'::regclass
    AND constraint_state.conname='backoffice_sales_order_lines_invoiceable_quantity_check';
  IF v_constraint IS NULL
    OR position('approved_overage_base_qty <= accepted_base_qty' in v_constraint)=0
    OR position('accepted_base_qty <= (ordered_base_qty + approved_overage_base_qty)' in v_constraint)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: accepted-overage quantity constraint drift';
  END IF;
END
$guard$;

DO $reconcile_guard$
BEGIN
  IF EXISTS(
    WITH overage AS (
      SELECT discrepancy.company_id,discrepancy.sales_order_line_id,
        round(sum(discrepancy.accepted_overage_base_qty),6) quantity_base
      FROM public.backoffice_sales_delivery_discrepancy_lines discrepancy
      WHERE discrepancy.accepted_overage_base_qty>0
      GROUP BY discrepancy.company_id,discrepancy.sales_order_line_id
    )
    SELECT 1 FROM public.backoffice_sales_order_lines line
    FULL JOIN overage ON overage.company_id=line.company_id
      AND overage.sales_order_line_id=line.id
    WHERE line.id IS NULL
      OR COALESCE(line.approved_overage_base_qty,0)<>COALESCE(overage.quantity_base,0)
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: accepted-overage source reconciliation ambiguous';
  END IF;
  IF EXISTS(
    WITH overage AS (
      SELECT discrepancy.company_id,discrepancy.sales_order_line_id,
        round(sum(discrepancy.accepted_overage_base_qty),6) quantity_base
      FROM public.backoffice_sales_delivery_discrepancy_lines discrepancy
      WHERE discrepancy.accepted_overage_base_qty>0
      GROUP BY discrepancy.company_id,discrepancy.sales_order_line_id
    )
    SELECT 1 FROM public.backoffice_sales_order_lines line
    JOIN overage ON overage.company_id=line.company_id
      AND overage.sales_order_line_id=line.id
    WHERE line.accepted_base_qty-overage.quantity_base<0
      OR line.accepted_base_qty-overage.quantity_base>line.ordered_base_qty
      OR line.returned_before_invoice_base_qty
        >line.accepted_base_qty-overage.quantity_base
      OR line.draft_invoice_allocated_base_qty+line.invoiced_base_qty
        >line.accepted_base_qty-overage.quantity_base-line.returned_before_invoice_base_qty
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: regular Invoice may already have consumed accepted overage';
  END IF;
END
$reconcile_guard$;

ALTER TABLE public.backoffice_sales_order_lines
  DROP CONSTRAINT backoffice_sales_order_lines_invoiceable_quantity_check;

WITH overage AS (
  SELECT discrepancy.company_id,discrepancy.sales_order_line_id,
    round(sum(discrepancy.accepted_overage_base_qty),6) quantity_base
  FROM public.backoffice_sales_delivery_discrepancy_lines discrepancy
  WHERE discrepancy.accepted_overage_base_qty>0
  GROUP BY discrepancy.company_id,discrepancy.sales_order_line_id
)
UPDATE public.backoffice_sales_order_lines line
SET accepted_base_qty=round(line.accepted_base_qty-overage.quantity_base,6)
FROM overage
WHERE line.company_id=overage.company_id AND line.id=overage.sales_order_line_id;

ALTER TABLE public.backoffice_sales_order_lines
  ADD CONSTRAINT backoffice_sales_order_lines_invoiceable_quantity_check CHECK(
    approved_overage_base_qty>=0
    AND accepted_base_qty>=0 AND accepted_base_qty<=ordered_base_qty
    AND returned_before_invoice_base_qty>=0
    AND returned_before_invoice_base_qty<=accepted_base_qty
    AND draft_invoice_allocated_base_qty>=0 AND invoiced_base_qty>=0
    AND draft_invoice_allocated_base_qty+invoiced_base_qty
      <=accepted_base_qty-returned_before_invoice_base_qty);

DO $patch$
DECLARE v_definition text;v_old text;v_new text;v_count integer;
BEGIN
  SELECT pg_get_functiondef(to_regprocedure(
    'private.resolve_backoffice_sales_overage_wrong_item_core(uuid,bigint,uuid,date,text)'))
  INTO STRICT v_definition;
  v_old:='accepted_base_qty=accepted_base_qty+v_qty,updated_at=v_now';
  v_new:='updated_at=v_now';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: accepted-overage resolver changed during migration';
  END IF;
  EXECUTE replace(v_definition,v_old,v_new);
  SELECT pg_get_functiondef(to_regprocedure(
    'private.resolve_backoffice_sales_overage_wrong_item_core(uuid,bigint,uuid,date,text)'))
  INTO STRICT v_definition;
  IF position(v_old in v_definition)>0
    OR position('approved_overage_base_qty=approved_overage_base_qty+v_qty' in v_definition)=0 THEN
    RAISE EXCEPTION 'MIGRATION_POSTCONDITION_FAILED: accepted-overage ledger split not installed';
  END IF;
END
$patch$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260912137000','backoffice_sales_accepted_overage_ledger_split_fix',
  'Separates regular accepted Sales Order quantity from accepted-overage discrepancy quantity, safely reconciles provable legacy rows, and prevents accepted overage from becoming invoiceable through both source ledgers');
NOTIFY pgrst,'reload schema';
COMMIT;
