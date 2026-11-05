BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('20261105100000_backoffice_ar_open_item_foundation',0));

DO $guard$
DECLARE v_missing text[];
BEGIN
  SELECT array_agg(required.version ORDER BY required.version)
  INTO v_missing
  FROM (VALUES
    ('20260810180000'),
    ('20260812140000'),
    ('20260827100000'),
    ('20260909156000'),
    ('20260909162000'),
    ('20260911160000'),
    ('20260917130000'),
    ('20260918150000'),
    ('20260928110000'),
    ('20261006140000')
  ) required(version)
  WHERE NOT EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations migration
    WHERE migration.version=required.version);
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_DEPENDENCY_MISSING: %',v_missing;
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20261105100000')
    OR to_regclass('public.ar_open_item_registry') IS NOT NULL
    OR to_regclass('public.ar_open_item_operations') IS NOT NULL
    OR to_regclass('public.ar_open_item_allocations') IS NOT NULL
    OR to_regclass('public.ar_open_item_audit') IS NOT NULL
    OR to_regprocedure('public.get_finance_ar_open_items(uuid,boolean)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: AR open-item foundation collision';
  END IF;
END
$guard$;

DO $business_precondition$
BEGIN
  IF EXISTS(
    SELECT 1 FROM private.backoffice_invoice_revisions revision
    JOIN public.company_sales_process_settings setting
      ON setting.company_id=revision.company_id
      AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
    WHERE revision.payable_delta<>0
      OR revision.prior_customer_id<>revision.new_customer_id) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: non-neutral Invoice revision requires Task 3 runtime design';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.customer_receipt_documents receipt
    JOIN public.company_sales_process_settings setting
      ON setting.company_id=receipt.company_id
      AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
    JOIN LATERAL (
      SELECT COALESCE(sum(allocation.allocated_amount),0) amount
      FROM public.customer_receipt_backoffice_invoice_allocations allocation
      WHERE allocation.company_id=receipt.company_id
        AND allocation.document_id=receipt.id
    ) backoffice ON true
    WHERE receipt.status='POSTED' AND backoffice.amount>receipt.total_amount) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Receipt slice exceeds Receipt total';
  END IF;
END
$business_precondition$;

CREATE TABLE public.ar_open_item_registry(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  scope_kind text NOT NULL DEFAULT 'BACKOFFICE',
  item_kind text NOT NULL,
  source_id uuid NOT NULL,
  financial_event_id uuid NOT NULL,
  journal_id uuid NOT NULL,
  journal_line_id uuid NOT NULL,
  customer_id uuid NOT NULL,
  account_id uuid NOT NULL,
  direction text NOT NULL,
  document_no text NOT NULL,
  document_date date NOT NULL,
  original_amount numeric(24,4) NOT NULL,
  source_snapshot jsonb NOT NULL,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ar_open_item_registry_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT ar_open_item_registry_source_unique
    UNIQUE(company_id,scope_kind,item_kind,source_id),
  CONSTRAINT ar_open_item_registry_event_fk FOREIGN KEY(company_id,financial_event_id)
    REFERENCES public.financial_events(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT ar_open_item_registry_journal_fk FOREIGN KEY(company_id,journal_id)
    REFERENCES public.finance_journals(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT ar_open_item_registry_journal_line_fk FOREIGN KEY(company_id,journal_line_id)
    REFERENCES public.finance_journal_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT ar_open_item_registry_customer_fk FOREIGN KEY(company_id,customer_id)
    REFERENCES public.customers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT ar_open_item_registry_account_fk FOREIGN KEY(company_id,account_id)
    REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT ar_open_item_registry_shape CHECK(
    scope_kind='BACKOFFICE'
    AND item_kind IN('INVOICE','RECEIPT','CREDIT_NOTE','PRICE_CORRECTION')
    AND direction IN('DEBIT','CREDIT')
    AND ((item_kind='INVOICE' AND direction='DEBIT')
      OR (item_kind IN('RECEIPT','CREDIT_NOTE') AND direction='CREDIT')
      OR item_kind='PRICE_CORRECTION')
    AND nullif(btrim(document_no),'') IS NOT NULL
    AND original_amount>0 AND jsonb_typeof(source_snapshot)='object')
);

CREATE INDEX ar_open_item_registry_customer_date_idx
  ON public.ar_open_item_registry(company_id,customer_id,document_date,id);

CREATE TABLE public.ar_open_item_operations(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  operation_kind text NOT NULL,
  idempotency_key text NOT NULL,
  request_hash text NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  operation_snapshot jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ar_open_item_operations_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT ar_open_item_operations_key_unique UNIQUE(company_id,idempotency_key),
  CONSTRAINT ar_open_item_operations_shape CHECK(
    operation_kind IN('BACKFILL_RECEIPT','BACKFILL_CREDIT_NOTE','BACKFILL_PRICE_CORRECTION')
    AND nullif(btrim(idempotency_key),'') IS NOT NULL
    AND request_hash~'^[0-9a-f]{32}$'
    AND jsonb_typeof(operation_snapshot)='object')
);

CREATE TABLE public.ar_open_item_allocations(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  debit_item_id uuid NOT NULL,
  credit_item_id uuid NOT NULL,
  allocated_amount numeric(24,4) NOT NULL,
  source_kind text NOT NULL,
  source_id uuid NOT NULL,
  reversal_of_allocation_id uuid,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ar_open_item_allocations_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT ar_open_item_allocations_source_unique UNIQUE(company_id,source_kind,source_id),
  CONSTRAINT ar_open_item_allocations_operation_fk FOREIGN KEY(company_id,operation_id)
    REFERENCES public.ar_open_item_operations(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT ar_open_item_allocations_debit_fk FOREIGN KEY(company_id,debit_item_id)
    REFERENCES public.ar_open_item_registry(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT ar_open_item_allocations_credit_fk FOREIGN KEY(company_id,credit_item_id)
    REFERENCES public.ar_open_item_registry(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT ar_open_item_allocations_reversal_fk FOREIGN KEY(company_id,reversal_of_allocation_id)
    REFERENCES public.ar_open_item_allocations(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT ar_open_item_allocations_shape CHECK(
    allocated_amount>0
    AND source_kind IN('RECEIPT_ALLOCATION','CREDIT_NOTE','PRICE_CORRECTION')
    AND reversal_of_allocation_id IS NULL)
);

CREATE INDEX ar_open_item_allocations_debit_idx
  ON public.ar_open_item_allocations(company_id,debit_item_id,created_at,id);
CREATE INDEX ar_open_item_allocations_credit_idx
  ON public.ar_open_item_allocations(company_id,credit_item_id,created_at,id);

CREATE TABLE public.ar_open_item_audit(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  entity_kind text NOT NULL,
  entity_id uuid NOT NULL,
  action text NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  state_snapshot jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ar_open_item_audit_shape CHECK(
    entity_kind IN('REGISTRY','OPERATION','ALLOCATION') AND action='INSERT'
    AND jsonb_typeof(state_snapshot)='object')
);

CREATE FUNCTION private.trg_ar_open_item_immutable()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'AR_OPEN_ITEM_HISTORY_IMMUTABLE';
END
$$;

CREATE FUNCTION private.trg_ar_open_item_audit_insert()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_entity text;v_actor uuid;v_state jsonb:=to_jsonb(NEW);
BEGIN
  v_entity:=CASE TG_TABLE_NAME
    WHEN 'ar_open_item_registry' THEN 'REGISTRY'
    WHEN 'ar_open_item_operations' THEN 'OPERATION'
    WHEN 'ar_open_item_allocations' THEN 'ALLOCATION'
    ELSE NULL END;
  v_actor:=CASE TG_TABLE_NAME
    WHEN 'ar_open_item_operations'
      THEN nullif(v_state->>'actor_id','')::uuid
    WHEN 'ar_open_item_registry'
      THEN nullif(v_state->>'created_by','')::uuid
    WHEN 'ar_open_item_allocations'
      THEN nullif(v_state->>'created_by','')::uuid
    ELSE NULL END;
  IF v_entity IS NULL OR v_actor IS NULL
    OR nullif(v_state->>'company_id','') IS NULL
    OR nullif(v_state->>'id','') IS NULL THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_AUDIT_SOURCE_SHAPE_INVALID: %',TG_TABLE_NAME;
  END IF;
  INSERT INTO public.ar_open_item_audit(company_id,entity_kind,entity_id,action,
    actor_id,state_snapshot)
  VALUES((v_state->>'company_id')::uuid,v_entity,(v_state->>'id')::uuid,
    'INSERT',v_actor,v_state);
  RETURN NEW;
END
$$;

CREATE FUNCTION private.trg_ar_open_item_validate_allocation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_debit public.ar_open_item_registry%rowtype;
  v_credit public.ar_open_item_registry%rowtype;v_debit_used numeric;v_credit_used numeric;
  v_operation_kind text;
BEGIN
  SELECT * INTO STRICT v_debit FROM public.ar_open_item_registry item
  WHERE item.company_id=NEW.company_id AND item.id=NEW.debit_item_id FOR UPDATE;
  SELECT * INTO STRICT v_credit FROM public.ar_open_item_registry item
  WHERE item.company_id=NEW.company_id AND item.id=NEW.credit_item_id FOR UPDATE;
  IF v_debit.direction<>'DEBIT' OR v_credit.direction<>'CREDIT'
    OR v_debit.customer_id<>v_credit.customer_id THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_ALLOCATION_IDENTITY_INVALID';
  END IF;
  SELECT operation.operation_kind INTO STRICT v_operation_kind
  FROM public.ar_open_item_operations operation
  WHERE operation.company_id=NEW.company_id AND operation.id=NEW.operation_id;
  IF (NEW.source_kind='RECEIPT_ALLOCATION' AND v_operation_kind<>'BACKFILL_RECEIPT')
    OR (NEW.source_kind='CREDIT_NOTE' AND v_operation_kind<>'BACKFILL_CREDIT_NOTE')
    OR (NEW.source_kind='PRICE_CORRECTION'
      AND v_operation_kind<>'BACKFILL_PRICE_CORRECTION') THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_ALLOCATION_OPERATION_INVALID';
  END IF;
  SELECT COALESCE(sum(allocation.allocated_amount),0) INTO v_debit_used
  FROM public.ar_open_item_allocations allocation
  WHERE allocation.company_id=NEW.company_id
    AND allocation.debit_item_id=NEW.debit_item_id;
  SELECT COALESCE(sum(allocation.allocated_amount),0) INTO v_credit_used
  FROM public.ar_open_item_allocations allocation
  WHERE allocation.company_id=NEW.company_id
    AND allocation.credit_item_id=NEW.credit_item_id;
  IF v_debit_used+NEW.allocated_amount>v_debit.original_amount
    OR v_credit_used+NEW.allocated_amount>v_credit.original_amount THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_ALLOCATION_EXCEEDS_RESIDUAL';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER ar_open_item_registry_immutable
BEFORE UPDATE OR DELETE ON public.ar_open_item_registry
FOR EACH ROW EXECUTE FUNCTION private.trg_ar_open_item_immutable();
CREATE TRIGGER ar_open_item_operations_immutable
BEFORE UPDATE OR DELETE ON public.ar_open_item_operations
FOR EACH ROW EXECUTE FUNCTION private.trg_ar_open_item_immutable();
CREATE TRIGGER ar_open_item_allocations_immutable
BEFORE UPDATE OR DELETE ON public.ar_open_item_allocations
FOR EACH ROW EXECUTE FUNCTION private.trg_ar_open_item_immutable();
CREATE TRIGGER ar_open_item_allocations_validate
BEFORE INSERT ON public.ar_open_item_allocations
FOR EACH ROW EXECUTE FUNCTION private.trg_ar_open_item_validate_allocation();
CREATE TRIGGER ar_open_item_audit_immutable
BEFORE UPDATE OR DELETE ON public.ar_open_item_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_ar_open_item_immutable();
CREATE TRIGGER ar_open_item_registry_audit
AFTER INSERT ON public.ar_open_item_registry
FOR EACH ROW EXECUTE FUNCTION private.trg_ar_open_item_audit_insert();
CREATE TRIGGER ar_open_item_operations_audit
AFTER INSERT ON public.ar_open_item_operations
FOR EACH ROW EXECUTE FUNCTION private.trg_ar_open_item_audit_insert();
CREATE TRIGGER ar_open_item_allocations_audit
AFTER INSERT ON public.ar_open_item_allocations
FOR EACH ROW EXECUTE FUNCTION private.trg_ar_open_item_audit_insert();

-- Canonical Invoice debit items. The account is resolved at the Event date; the
-- snapshot function key is deliberately not used as universal identity.
WITH invoice_source AS (
  SELECT invoice.*,journal.id AS journal_id,line.id AS journal_line_id,
    line.account_id,line.debit AS item_amount
  FROM public.backoffice_sales_invoices invoice
  JOIN public.company_sales_process_settings setting ON setting.company_id=invoice.company_id
    AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  JOIN public.financial_events event ON event.company_id=invoice.company_id
    AND event.id=invoice.financial_event_id
  JOIN public.finance_journals journal ON journal.company_id=event.company_id
    AND journal.financial_event_id=event.id AND journal.status='POSTED'
  JOIN LATERAL (
    SELECT candidate.account_id
    FROM (
      SELECT rule.account_id,rule.rule_version AS version
      FROM public.transaction_account_rules rule
      WHERE rule.company_id=event.company_id
        AND rule.transaction_category_id=event.transaction_category_id
        AND rule.system_key=event.system_event_key
        AND rule.account_function_key='CUSTOMER_RECEIVABLE'
        AND rule.status='ACTIVE' AND rule.effective_from<=event.event_date
        AND (rule.effective_to IS NULL OR rule.effective_to>event.event_date)
      UNION ALL
      SELECT fallback.account_id,fallback.fallback_version
      FROM public.company_account_function_fallbacks fallback
      WHERE fallback.company_id=event.company_id
        AND fallback.account_function_key='CUSTOMER_RECEIVABLE'
        AND fallback.status='ACTIVE' AND fallback.effective_from<=event.event_date
        AND (fallback.effective_to IS NULL OR fallback.effective_to>event.event_date)
        AND NOT EXISTS(
          SELECT 1 FROM public.transaction_account_rules rule
          WHERE rule.company_id=event.company_id
            AND rule.transaction_category_id=event.transaction_category_id
            AND rule.system_key=event.system_event_key
            AND rule.account_function_key='CUSTOMER_RECEIVABLE'
            AND rule.status='ACTIVE' AND rule.effective_from<=event.event_date
            AND (rule.effective_to IS NULL OR rule.effective_to>event.event_date))
    ) candidate ORDER BY candidate.version DESC,candidate.account_id LIMIT 1
  ) routed ON true
  JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
    AND line.journal_id=journal.id AND line.account_id=routed.account_id
    AND line.customer_id=invoice.customer_id AND line.debit=invoice.grand_total
    AND line.credit=0
  WHERE invoice.status='POSTED' AND invoice.grand_total>0
)
INSERT INTO public.ar_open_item_registry(company_id,item_kind,source_id,
  financial_event_id,journal_id,journal_line_id,customer_id,account_id,direction,
  document_no,document_date,original_amount,source_snapshot,created_by)
SELECT source.company_id,'INVOICE',source.id,source.financial_event_id,
  source.journal_id,source.journal_line_id,source.customer_id,source.account_id,'DEBIT',
  source.invoice_no,source.invoice_date,source.item_amount,
  jsonb_build_object('sourceTable','backoffice_sales_invoices','invoiceType',source.invoice_type,
    'masterVersion',source.master_version),COALESCE(source.posted_by,source.created_by)
FROM invoice_source source;

-- Receipt items are Backoffice slices, not the whole credit line. This keeps
-- mixed Retail/Backoffice Receipt portions outside this foundation.
WITH receipt_source AS (
  SELECT receipt.*,journal.id AS journal_id,line.id AS journal_line_id,
    line.account_id,sum(allocation.allocated_amount)::numeric(24,4) AS slice_amount
  FROM public.customer_receipt_documents receipt
  JOIN public.company_sales_process_settings setting ON setting.company_id=receipt.company_id
    AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  JOIN public.customer_receipt_backoffice_invoice_allocations allocation
    ON allocation.company_id=receipt.company_id AND allocation.document_id=receipt.id
  JOIN public.finance_journals journal ON journal.company_id=receipt.company_id
    AND journal.financial_event_id=receipt.financial_event_id AND journal.status='POSTED'
  JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
    AND line.journal_id=journal.id
    AND line.account_id=receipt.receivable_account_id_snapshot
    AND line.customer_id=receipt.customer_id AND line.debit=0
    AND line.credit=receipt.total_amount
  WHERE receipt.status='POSTED'
  GROUP BY receipt.id,journal.id,line.id,line.account_id
)
INSERT INTO public.ar_open_item_registry(company_id,item_kind,source_id,
  financial_event_id,journal_id,journal_line_id,customer_id,account_id,direction,
  document_no,document_date,original_amount,source_snapshot,created_by)
SELECT source.company_id,'RECEIPT',source.id,source.financial_event_id,
  source.journal_id,source.journal_line_id,source.customer_id,source.account_id,'CREDIT',
  source.receipt_no,source.receipt_date,source.slice_amount,
  jsonb_build_object('sourceTable','customer_receipt_documents',
    'backofficeSliceAmount',source.slice_amount,'receiptTotalAmount',source.total_amount,
    'masterVersion',source.master_version),COALESCE(source.posted_by,source.created_by)
FROM receipt_source source;

WITH credit_source AS (
  SELECT note.*,journal.id AS journal_id,line.id AS journal_line_id,line.account_id
  FROM public.backoffice_sales_credit_notes note
  JOIN public.company_sales_process_settings setting ON setting.company_id=note.company_id
    AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  JOIN public.finance_journals journal ON journal.company_id=note.company_id
    AND journal.financial_event_id=note.financial_event_id AND journal.status='POSTED'
  JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
    AND line.journal_id=journal.id AND line.customer_id=note.customer_id
    AND line.debit=0 AND line.credit=note.ar_reduction_amount
  WHERE note.status='POSTED' AND note.source_kind='BACKOFFICE'
    AND note.ar_reduction_amount>0
)
INSERT INTO public.ar_open_item_registry(company_id,item_kind,source_id,
  financial_event_id,journal_id,journal_line_id,customer_id,account_id,direction,
  document_no,document_date,original_amount,source_snapshot,created_by)
SELECT source.company_id,'CREDIT_NOTE',source.id,source.financial_event_id,
  source.journal_id,source.journal_line_id,source.customer_id,source.account_id,'CREDIT',
  source.credit_note_no,source.credit_note_date,source.ar_reduction_amount,
  jsonb_build_object('sourceTable','backoffice_sales_credit_notes',
    'sourceInvoiceId',source.source_invoice_id,'masterVersion',source.master_version),
  COALESCE(source.posted_by,source.created_by)
FROM credit_source source;

WITH correction_source AS (
  SELECT correction.*,invoice.customer_id,journal.id AS journal_id,
    line.id AS journal_line_id,line.account_id,
    CASE WHEN correction.ar_adjustment_amount>0 THEN 'DEBIT' ELSE 'CREDIT' END AS direction,
    abs(correction.ar_adjustment_amount)::numeric(24,4) AS item_amount
  FROM public.backoffice_sales_invoice_price_corrections correction
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=correction.company_id
    AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  JOIN public.backoffice_sales_invoices invoice ON invoice.company_id=correction.company_id
    AND invoice.id=correction.source_invoice_id
  JOIN public.finance_journals journal ON journal.company_id=correction.company_id
    AND journal.financial_event_id=correction.financial_event_id AND journal.status='POSTED'
  JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
    AND line.journal_id=journal.id AND line.customer_id=invoice.customer_id
    AND ((correction.ar_adjustment_amount>0 AND line.debit=correction.ar_adjustment_amount
          AND line.credit=0)
      OR (correction.ar_adjustment_amount<0 AND line.credit=-correction.ar_adjustment_amount
          AND line.debit=0))
  WHERE correction.status='POSTED' AND correction.ar_adjustment_amount<>0
)
INSERT INTO public.ar_open_item_registry(company_id,item_kind,source_id,
  financial_event_id,journal_id,journal_line_id,customer_id,account_id,direction,
  document_no,document_date,original_amount,source_snapshot,created_by)
SELECT source.company_id,'PRICE_CORRECTION',source.id,source.financial_event_id,
  source.journal_id,source.journal_line_id,source.customer_id,source.account_id,source.direction,
  source.correction_no,source.correction_date,source.item_amount,
  jsonb_build_object('sourceTable','backoffice_sales_invoice_price_corrections',
    'sourceInvoiceId',source.source_invoice_id,'correctionKind',source.correction_kind),
  source.posted_by
FROM correction_source source;

-- Existing receipt allocations become immutable append-only allocations.
WITH source_rows AS (
  SELECT allocation.*,receipt.posted_by AS actor_id,
    debit.id AS debit_item_id,credit.id AS credit_item_id
  FROM public.customer_receipt_backoffice_invoice_allocations allocation
  JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
    AND receipt.id=allocation.document_id AND receipt.status='POSTED'
  JOIN public.ar_open_item_registry debit ON debit.company_id=allocation.company_id
    AND debit.item_kind='INVOICE' AND debit.source_id=allocation.invoice_id
  JOIN public.ar_open_item_registry credit ON credit.company_id=allocation.company_id
    AND credit.item_kind='RECEIPT' AND credit.source_id=allocation.document_id
),operations AS (
  INSERT INTO public.ar_open_item_operations(company_id,operation_kind,idempotency_key,
    request_hash,actor_id,operation_snapshot)
  SELECT source.company_id,'BACKFILL_RECEIPT','BACKFILL_RECEIPT|'||source.id,
    md5(source.company_id::text||'|'||source.id::text||'|'||source.allocated_amount::text),
    source.actor_id,jsonb_build_object('sourceTable',
      'customer_receipt_backoffice_invoice_allocations','sourceId',source.id)
  FROM source_rows source RETURNING company_id,id,idempotency_key
)
INSERT INTO public.ar_open_item_allocations(company_id,operation_id,debit_item_id,
  credit_item_id,allocated_amount,source_kind,source_id,created_by)
SELECT source.company_id,operation.id,source.debit_item_id,source.credit_item_id,
  source.allocated_amount,'RECEIPT_ALLOCATION',source.id,source.actor_id
FROM source_rows source JOIN operations operation ON operation.company_id=source.company_id
  AND operation.idempotency_key='BACKFILL_RECEIPT|'||source.id;

WITH source_rows AS (
  SELECT note.*,debit.id AS debit_item_id,credit.id AS credit_item_id
  FROM public.backoffice_sales_credit_notes note
  JOIN public.ar_open_item_registry debit ON debit.company_id=note.company_id
    AND debit.item_kind='INVOICE' AND debit.source_id=note.source_invoice_id
  JOIN public.ar_open_item_registry credit ON credit.company_id=note.company_id
    AND credit.item_kind='CREDIT_NOTE' AND credit.source_id=note.id
  WHERE note.status='POSTED' AND note.source_kind='BACKOFFICE'
    AND note.ar_reduction_amount>0
),operations AS (
  INSERT INTO public.ar_open_item_operations(company_id,operation_kind,idempotency_key,
    request_hash,actor_id,operation_snapshot)
  SELECT source.company_id,'BACKFILL_CREDIT_NOTE','BACKFILL_CREDIT_NOTE|'||source.id,
    md5(source.company_id::text||'|'||source.id::text||'|'||source.ar_reduction_amount::text),
    source.posted_by,jsonb_build_object('sourceTable','backoffice_sales_credit_notes',
      'sourceId',source.id)
  FROM source_rows source RETURNING company_id,id,idempotency_key
)
INSERT INTO public.ar_open_item_allocations(company_id,operation_id,debit_item_id,
  credit_item_id,allocated_amount,source_kind,source_id,created_by)
SELECT source.company_id,operation.id,source.debit_item_id,source.credit_item_id,
  source.ar_reduction_amount,'CREDIT_NOTE',source.id,source.posted_by
FROM source_rows source JOIN operations operation ON operation.company_id=source.company_id
  AND operation.idempotency_key='BACKFILL_CREDIT_NOTE|'||source.id;

WITH source_rows AS (
  SELECT correction.*,debit.id AS debit_item_id,credit.id AS credit_item_id
  FROM public.backoffice_sales_invoice_price_corrections correction
  JOIN public.ar_open_item_registry debit ON debit.company_id=correction.company_id
    AND debit.item_kind='INVOICE' AND debit.source_id=correction.source_invoice_id
  JOIN public.ar_open_item_registry credit ON credit.company_id=correction.company_id
    AND credit.item_kind='PRICE_CORRECTION' AND credit.source_id=correction.id
    AND credit.direction='CREDIT'
  WHERE correction.status='POSTED' AND correction.ar_adjustment_amount<0
),operations AS (
  INSERT INTO public.ar_open_item_operations(company_id,operation_kind,idempotency_key,
    request_hash,actor_id,operation_snapshot)
  SELECT source.company_id,'BACKFILL_PRICE_CORRECTION',
    'BACKFILL_PRICE_CORRECTION|'||source.id,
    md5(source.company_id::text||'|'||source.id::text||'|'||source.ar_adjustment_amount::text),
    source.posted_by,jsonb_build_object('sourceTable',
      'backoffice_sales_invoice_price_corrections','sourceId',source.id)
  FROM source_rows source RETURNING company_id,id,idempotency_key
)
INSERT INTO public.ar_open_item_allocations(company_id,operation_id,debit_item_id,
  credit_item_id,allocated_amount,source_kind,source_id,created_by)
SELECT source.company_id,operation.id,source.debit_item_id,source.credit_item_id,
  -source.ar_adjustment_amount,'PRICE_CORRECTION',source.id,source.posted_by
FROM source_rows source JOIN operations operation ON operation.company_id=source.company_id
  AND operation.idempotency_key='BACKFILL_PRICE_CORRECTION|'||source.id;

DO $backfill_contract$
DECLARE v_expected bigint;v_actual bigint;
BEGIN
  SELECT count(*) INTO v_expected FROM public.backoffice_sales_invoices
  WHERE status='POSTED' AND grand_total>0 AND EXISTS(
    SELECT 1 FROM public.company_sales_process_settings setting
    WHERE setting.company_id=backoffice_sales_invoices.company_id
      AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE');
  SELECT count(*) INTO v_actual FROM public.ar_open_item_registry
  WHERE item_kind='INVOICE';
  IF v_actual<>v_expected THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_BACKFILL_INVOICE_MISMATCH: expected %, actual %',v_expected,v_actual;
  END IF;

  SELECT count(DISTINCT receipt.id) INTO v_expected
  FROM public.customer_receipt_documents receipt
  JOIN public.company_sales_process_settings setting ON setting.company_id=receipt.company_id
    AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  JOIN public.customer_receipt_backoffice_invoice_allocations allocation
    ON allocation.company_id=receipt.company_id AND allocation.document_id=receipt.id
  WHERE receipt.status='POSTED';
  SELECT count(*) INTO v_actual FROM public.ar_open_item_registry
  WHERE item_kind='RECEIPT';
  IF v_actual<>v_expected THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_BACKFILL_RECEIPT_MISMATCH: expected %, actual %',v_expected,v_actual;
  END IF;

  SELECT count(*) INTO v_expected FROM public.backoffice_sales_credit_notes
  WHERE status='POSTED' AND source_kind='BACKOFFICE' AND ar_reduction_amount>0
    AND EXISTS(SELECT 1 FROM public.company_sales_process_settings setting
      WHERE setting.company_id=backoffice_sales_credit_notes.company_id
        AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE');
  SELECT count(*) INTO v_actual FROM public.ar_open_item_registry
  WHERE item_kind='CREDIT_NOTE';
  IF v_actual<>v_expected THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_BACKFILL_CREDIT_NOTE_MISMATCH: expected %, actual %',v_expected,v_actual;
  END IF;

  SELECT count(*) INTO v_expected
  FROM public.backoffice_sales_invoice_price_corrections
  WHERE status='POSTED' AND ar_adjustment_amount<>0
    AND EXISTS(SELECT 1 FROM public.company_sales_process_settings setting
      WHERE setting.company_id=backoffice_sales_invoice_price_corrections.company_id
        AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE');
  SELECT count(*) INTO v_actual FROM public.ar_open_item_registry
  WHERE item_kind='PRICE_CORRECTION';
  IF v_actual<>v_expected THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_BACKFILL_PRICE_CORRECTION_MISMATCH: expected %, actual %',v_expected,v_actual;
  END IF;

  SELECT count(*) INTO v_expected
  FROM public.customer_receipt_backoffice_invoice_allocations allocation
  JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
    AND receipt.id=allocation.document_id AND receipt.status='POSTED'
  JOIN public.company_sales_process_settings setting ON setting.company_id=receipt.company_id
    AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE';
  SELECT count(*) INTO v_actual FROM public.ar_open_item_allocations
  WHERE source_kind='RECEIPT_ALLOCATION';
  IF v_actual<>v_expected THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_BACKFILL_RECEIPT_ALLOCATION_MISMATCH: expected %, actual %',v_expected,v_actual;
  END IF;

  IF EXISTS(
    SELECT 1 FROM public.ar_open_item_registry item
    LEFT JOIN public.ar_open_item_allocations allocation
      ON allocation.company_id=item.company_id
      AND (allocation.debit_item_id=item.id OR allocation.credit_item_id=item.id)
    GROUP BY item.company_id,item.id,item.original_amount
    HAVING COALESCE(sum(allocation.allocated_amount),0)>item.original_amount) THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_BACKFILL_OVERALLOCATION';
  END IF;
  IF (SELECT count(*) FROM public.ar_open_item_audit)<>
      (SELECT count(*) FROM public.ar_open_item_registry)
      +(SELECT count(*) FROM public.ar_open_item_operations)
      +(SELECT count(*) FROM public.ar_open_item_allocations) THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_BACKFILL_AUDIT_MISMATCH';
  END IF;
  IF EXISTS(
      SELECT 1 FROM public.ar_open_item_audit audit
      LEFT JOIN public.ar_open_item_registry registry
        ON registry.company_id=audit.company_id AND registry.id=audit.entity_id
      WHERE audit.entity_kind='REGISTRY'
        AND (registry.id IS NULL OR audit.actor_id<>registry.created_by
          OR audit.state_snapshot IS DISTINCT FROM to_jsonb(registry)))
    OR EXISTS(
      SELECT 1 FROM public.ar_open_item_audit audit
      LEFT JOIN public.ar_open_item_operations operation
        ON operation.company_id=audit.company_id AND operation.id=audit.entity_id
      WHERE audit.entity_kind='OPERATION'
        AND (operation.id IS NULL OR audit.actor_id<>operation.actor_id
          OR audit.state_snapshot IS DISTINCT FROM to_jsonb(operation)))
    OR EXISTS(
      SELECT 1 FROM public.ar_open_item_audit audit
      LEFT JOIN public.ar_open_item_allocations allocation
        ON allocation.company_id=audit.company_id AND allocation.id=audit.entity_id
      WHERE audit.entity_kind='ALLOCATION'
        AND (allocation.id IS NULL OR audit.actor_id<>allocation.created_by
          OR audit.state_snapshot IS DISTINCT FROM to_jsonb(allocation))) THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_BACKFILL_AUDIT_LINEAGE_INVALID';
  END IF;
END
$backfill_contract$;

CREATE FUNCTION public.get_finance_ar_open_items(
  p_customer_id uuid DEFAULT NULL,p_include_settled boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_permission jsonb;
BEGIN
  v_permission:=private.acp_require_permission_capability(
    v_company,'finance.customer_receipts','VIEW');
  RETURN (
    WITH allocated AS (
      SELECT item.id,
        COALESCE(sum(CASE WHEN item.direction='DEBIT' THEN allocation.allocated_amount
          ELSE 0 END) FILTER(WHERE allocation.debit_item_id=item.id),0)
        +COALESCE(sum(CASE WHEN item.direction='CREDIT' THEN allocation.allocated_amount
          ELSE 0 END) FILTER(WHERE allocation.credit_item_id=item.id),0) AS amount
      FROM public.ar_open_item_registry item
      LEFT JOIN public.ar_open_item_allocations allocation
        ON allocation.company_id=item.company_id
        AND (allocation.debit_item_id=item.id OR allocation.credit_item_id=item.id)
      WHERE item.company_id=v_company GROUP BY item.id
    ),rows AS (
      SELECT item.*,round(item.original_amount-allocated.amount,4) AS residual_amount
      FROM public.ar_open_item_registry item
      JOIN allocated ON allocated.id=item.id
      WHERE item.company_id=v_company
        AND (p_customer_id IS NULL OR item.customer_id=p_customer_id)
        AND (p_include_settled OR round(item.original_amount-allocated.amount,4)>0)
    )
    SELECT jsonb_build_object('companyId',v_company,'customerId',p_customer_id,
      'includeSettled',p_include_settled,
      'debitResidual',COALESCE(sum(residual_amount) FILTER(WHERE direction='DEBIT'),0),
      'creditResidual',COALESCE(sum(residual_amount) FILTER(WHERE direction='CREDIT'),0),
      'items',COALESCE(jsonb_agg(jsonb_build_object(
        'id',id,'itemKind',item_kind,'sourceId',source_id,'direction',direction,
        'documentNo',document_no,'documentDate',document_date,'customerId',customer_id,
        'accountId',account_id,'originalAmount',original_amount,
        'allocatedAmount',original_amount-residual_amount,'residualAmount',residual_amount,
        'sourceSnapshot',source_snapshot)
        ORDER BY document_date,document_no,id),'[]'::jsonb)) FROM rows);
END
$$;

ALTER TABLE public.ar_open_item_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ar_open_item_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ar_open_item_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ar_open_item_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.ar_open_item_registry,public.ar_open_item_operations,
  public.ar_open_item_allocations,public.ar_open_item_audit FROM PUBLIC,anon,authenticated;
GRANT ALL ON TABLE public.ar_open_item_registry,public.ar_open_item_operations,
  public.ar_open_item_allocations,public.ar_open_item_audit TO service_role;
REVOKE ALL ON FUNCTION private.trg_ar_open_item_immutable(),
  private.trg_ar_open_item_audit_insert(),private.trg_ar_open_item_validate_allocation()
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_ar_open_item_immutable(),
  private.trg_ar_open_item_audit_insert(),private.trg_ar_open_item_validate_allocation()
  TO service_role;
REVOKE ALL ON FUNCTION public.get_finance_ar_open_items(uuid,boolean)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_finance_ar_open_items(uuid,boolean)
  TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261105100000','backoffice_ar_open_item_foundation',
  'Append-only Backoffice AR open-item registry/allocation/audit foundation and read RPC; immutable Posted Journals, Retail/POS, Customer Balance, Stock/FIFO and posting runtimes preserved');
NOTIFY pgrst,'reload schema';
COMMIT;
