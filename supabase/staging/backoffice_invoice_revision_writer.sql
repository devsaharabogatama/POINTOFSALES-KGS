-- STAGING DEVELOPMENT CANDIDATE. Loaded only inside the rollback harness.
CREATE TABLE private.backoffice_invoice_revisions(
  company_id uuid NOT NULL REFERENCES public.companies(id),id uuid NOT NULL DEFAULT gen_random_uuid(),
  operation_id uuid NOT NULL,invoice_id uuid NOT NULL,revision_no bigint NOT NULL,
  prior_customer_id uuid NOT NULL,new_customer_id uuid NOT NULL,
  prior_invoice_date date NOT NULL,new_invoice_date date NOT NULL,
  payable_delta numeric(24,4) NOT NULL,source_snapshot jsonb NOT NULL,
  execution_plan jsonb NOT NULL,journal_ids jsonb NOT NULL,response_snapshot jsonb NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id),revision_date date NOT NULL,
  posted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(company_id,id),UNIQUE(company_id,operation_id),UNIQUE(company_id,invoice_id,revision_no),
  FOREIGN KEY(company_id,invoice_id) REFERENCES public.backoffice_sales_invoices(company_id,id),
  CHECK(revision_no>0 AND jsonb_typeof(source_snapshot)='object' AND jsonb_typeof(execution_plan)='object'
    AND jsonb_typeof(journal_ids)='array' AND jsonb_typeof(response_snapshot)='object'));
CREATE TABLE private.backoffice_invoice_revision_lines(
  company_id uuid NOT NULL,revision_id uuid NOT NULL,invoice_id uuid NOT NULL,invoice_line_id uuid NOT NULL,
  new_unit_price numeric(24,4) NOT NULL,new_discount_amount numeric(24,4) NOT NULL,
  before_amounts jsonb NOT NULL,after_amounts jsonb NOT NULL,
  PRIMARY KEY(company_id,revision_id,invoice_line_id),
  FOREIGN KEY(company_id,revision_id) REFERENCES private.backoffice_invoice_revisions(company_id,id),
  FOREIGN KEY(company_id,invoice_line_id) REFERENCES public.backoffice_sales_invoice_lines(company_id,id));
CREATE TABLE private.backoffice_invoice_revision_settlement_attributions(
  company_id uuid NOT NULL,revision_id uuid NOT NULL,source_type text NOT NULL,source_id uuid NOT NULL,
  action text NOT NULL,amount numeric(24,4) NOT NULL,from_customer_id uuid NOT NULL,to_customer_id uuid NOT NULL,
  source_snapshot jsonb NOT NULL,PRIMARY KEY(company_id,revision_id,source_type,source_id,action),
  FOREIGN KEY(company_id,revision_id) REFERENCES private.backoffice_invoice_revisions(company_id,id),
  CHECK(source_type IN('RECEIPT_ALLOCATION','DOWN_PAYMENT_APPLICATION') AND amount>0));
ALTER TABLE private.backoffice_invoice_revisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.backoffice_invoice_revision_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.backoffice_invoice_revision_settlement_attributions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.backoffice_invoice_revisions,private.backoffice_invoice_revision_lines,
  private.backoffice_invoice_revision_settlement_attributions FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION private.guard_backoffice_invoice_revision_history() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $g$ BEGIN RAISE EXCEPTION 'INVOICE_REVISION_HISTORY_IMMUTABLE'; END $g$;
CREATE TRIGGER invoice_revision_history_immutable BEFORE UPDATE OR DELETE ON private.backoffice_invoice_revisions
FOR EACH ROW EXECUTE FUNCTION private.guard_backoffice_invoice_revision_history();
CREATE TRIGGER invoice_revision_lines_immutable BEFORE UPDATE OR DELETE ON private.backoffice_invoice_revision_lines
FOR EACH ROW EXECUTE FUNCTION private.guard_backoffice_invoice_revision_history();
CREATE TRIGGER invoice_revision_settlement_immutable BEFORE UPDATE OR DELETE ON private.backoffice_invoice_revision_settlement_attributions
FOR EACH ROW EXECUTE FUNCTION private.guard_backoffice_invoice_revision_history();
REVOKE ALL ON FUNCTION private.guard_backoffice_invoice_revision_history() FROM PUBLIC,anon,authenticated,service_role;

ALTER FUNCTION private.backoffice_invoice_effective_total(uuid,uuid,date)
  RENAME TO backoffice_invoice_effective_total_before_unified_revision;
CREATE FUNCTION private.backoffice_invoice_effective_total(p_company_id uuid,p_invoice_id uuid,p_as_of date DEFAULT NULL)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $f$
 SELECT round(private.backoffice_invoice_effective_total_before_unified_revision(p_company_id,p_invoice_id,p_as_of)+
   COALESCE((SELECT sum(r.payable_delta) FROM private.backoffice_invoice_revisions r
     WHERE r.company_id=p_company_id AND r.invoice_id=p_invoice_id
       AND (p_as_of IS NULL OR r.revision_date<=p_as_of)),0),4)
$f$;
REVOKE ALL ON FUNCTION private.backoffice_invoice_effective_total(uuid,uuid,date) FROM PUBLIC,anon,authenticated,service_role;

ALTER FUNCTION private.backoffice_invoice_effective_entered_unit_price(uuid,uuid)
  RENAME TO backoffice_invoice_effective_entered_unit_price_before_unified_revision;
CREATE FUNCTION private.backoffice_invoice_effective_entered_unit_price(p_company_id uuid,p_invoice_line_id uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $f$
 SELECT COALESCE((SELECT l.new_unit_price FROM private.backoffice_invoice_revision_lines l
   JOIN private.backoffice_invoice_revisions r ON r.company_id=l.company_id AND r.id=l.revision_id
   WHERE l.company_id=p_company_id AND l.invoice_line_id=p_invoice_line_id
   ORDER BY r.revision_no DESC LIMIT 1),
   private.backoffice_invoice_effective_entered_unit_price_before_unified_revision(p_company_id,p_invoice_line_id))
$f$;
REVOKE ALL ON FUNCTION private.backoffice_invoice_effective_entered_unit_price(uuid,uuid)
  FROM PUBLIC,anon,authenticated,service_role;

ALTER FUNCTION private.backoffice_invoice_effective_line_amounts(uuid,uuid)
  RENAME TO backoffice_invoice_effective_line_amounts_before_unified_revision;
CREATE FUNCTION private.backoffice_invoice_effective_line_amounts(p_company_id uuid,p_invoice_line_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $f$
DECLARE source public.backoffice_sales_invoice_lines%rowtype;price numeric(24,4);discount numeric(24,4);
 gross numeric(24,4);dpp numeric(24,4);tax numeric(24,4);tax_result jsonb;tax_line jsonb;revision bigint;
BEGIN
 SELECT * INTO source FROM public.backoffice_sales_invoice_lines l
  WHERE l.company_id=p_company_id AND l.id=p_invoice_line_id;
 IF NOT FOUND OR source.line_type<>'PRODUCT' OR source.source_kind<>'SALES_ORDER' THEN
  RAISE EXCEPTION 'BACKOFFICE_INVOICE_EFFECTIVE_LINE_INVALID'; END IF;
 SELECT l.new_unit_price,l.new_discount_amount,r.revision_no INTO price,discount,revision
 FROM private.backoffice_invoice_revision_lines l JOIN private.backoffice_invoice_revisions r
  ON r.company_id=l.company_id AND r.id=l.revision_id
 WHERE l.company_id=p_company_id AND l.invoice_line_id=p_invoice_line_id
 ORDER BY r.revision_no DESC LIMIT 1;
 IF NOT FOUND THEN RETURN private.backoffice_invoice_effective_line_amounts_before_unified_revision(
   p_company_id,p_invoice_line_id); END IF;
 gross:=round(source.quantity_uom*price-discount,4);
 IF gross<0 THEN RAISE EXCEPTION 'INVOICE_DISCOUNT_EXCEEDS_CORRECTED_LINE_TOTAL'; END IF;
 dpp:=gross;tax:=0;
 IF COALESCE((source.source_snapshot->>'taxApplied')::boolean,false) THEN
  IF source.source_snapshot->>'taxPriceMode'<>'INCLUSIVE'
   OR NULLIF(source.source_snapshot->>'taxRatePercent','') IS NULL
   OR NULLIF(source.source_snapshot->>'taxCalculationScope','') IS NULL THEN
   RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_TAX_SOURCE_INVALID'; END IF;
  tax_result:=private.calculate_tax_group(jsonb_build_array(
   jsonb_build_object('lineKey',source.id::text,'amount',gross)),
   (source.source_snapshot->>'taxRatePercent')::numeric,'SALES',
   source.source_snapshot->>'taxPriceMode',source.source_snapshot->>'taxCalculationScope');
  tax_line:=tax_result->'lines'->0;dpp:=round((tax_line->>'taxBase')::numeric,4);
  tax:=round((tax_line->>'taxAmount')::numeric,4);
 END IF;
 RETURN jsonb_build_object('enteredUnitPrice',price,'chargeAmount',round(dpp+discount,4),
  'discountAmount',discount,'lineAmount',dpp,'taxAmount',tax,'priceRevision',revision);
END
$f$;
REVOKE ALL ON FUNCTION private.backoffice_invoice_effective_line_amounts(uuid,uuid)
  FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION private.backoffice_invoice_effective_identity(p_company_id uuid,p_invoice_id uuid,p_as_of date DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $f$
 SELECT jsonb_build_object('customerId',COALESCE(r.new_customer_id,i.customer_id),
   'invoiceDate',COALESCE(r.new_invoice_date,i.invoice_date),'revision',COALESCE(r.revision_no,0))
 FROM public.backoffice_sales_invoices i LEFT JOIN LATERAL(
   SELECT x.* FROM private.backoffice_invoice_revisions x WHERE x.company_id=i.company_id AND x.invoice_id=i.id
     AND (p_as_of IS NULL OR x.revision_date<=p_as_of) ORDER BY x.revision_no DESC LIMIT 1) r ON true
 WHERE i.company_id=p_company_id AND i.id=p_invoice_id
$f$;
REVOKE ALL ON FUNCTION private.backoffice_invoice_effective_identity(uuid,uuid,date) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION private.post_backoffice_invoice_revision_journal_leg(p_invoice_id uuid,p_revision_id uuid,p_leg_no integer,
  p_leg_name text,p_leg jsonb,p_journal_type text,p_reversal_of uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $post$
DECLARE c uuid:=public.private_active_company_id();actor uuid:=auth.uid();invoice public.backoffice_sales_invoices%rowtype;
 source_event public.financial_events%rowtype;period public.accounting_periods%rowtype;event_id uuid:=gen_random_uuid();
 journal_id uuid:=gen_random_uuid();d date:=(p_leg->>'accountingDate')::date;line jsonb;n integer:=0;j public.finance_journals%rowtype;
BEGIN
 IF jsonb_array_length(p_leg->'lines')=0 THEN RETURN NULL; END IF;
 SELECT i.* INTO STRICT invoice FROM public.backoffice_sales_invoices i
   WHERE i.company_id=c AND i.id=p_invoice_id;
 SELECT * INTO STRICT source_event FROM public.financial_events e WHERE e.company_id=c AND e.id=invoice.financial_event_id;
 SELECT * INTO STRICT period FROM public.accounting_periods p WHERE p.company_id=c AND d BETWEEN p.start_date AND p.end_date
   AND p.status IN('OPEN','REOPENED') ORDER BY p.start_date DESC,p.id LIMIT 1 FOR SHARE;
 INSERT INTO public.financial_events(id,event_code,event_type,source_table,source_id,event_date,event_version,
   idempotency_key,amounts,status,created_by,company_id,store_id,system_event_key,transaction_category_id,transaction_rule_version)
 VALUES(event_id,'INV-REV-'||replace(p_revision_id::text,'-','')||'-'||p_leg_no,'SALE_REVISED',
   'backoffice_invoice_revisions',p_revision_id,d::timestamptz,p_leg_no,
   'INVOICE_REVISION_EVENT|'||c||'|'||p_revision_id||'|'||p_leg_no,
   jsonb_build_object('revisionId',p_revision_id,'leg',p_leg_name),'HOLD',actor,c,invoice.store_id,
   source_event.system_event_key,source_event.transaction_category_id,source_event.transaction_rule_version);
 INSERT INTO public.finance_journals(id,company_id,journal_no,journal_type,accounting_period_id,accounting_date,
   original_event_date,source_type,source_id,source_version,financial_event_id,idempotency_key,system_event_key,
   transaction_category_id,transaction_rule_version,store_id,warehouse_id,description,status,reversal_of_journal_id,created_by)
 VALUES(journal_id,c,'IRJ-'||replace(journal_id::text,'-',''),p_journal_type,period.id,d,d,
   'backoffice_invoice_revisions',p_revision_id,p_leg_no,event_id,
   'INVOICE_REVISION_JOURNAL|'||c||'|'||p_revision_id||'|'||p_leg_no,source_event.system_event_key,
   source_event.transaction_category_id,source_event.transaction_rule_version,invoice.store_id,invoice.warehouse_id,
   'Koreksi Invoice '||invoice.invoice_no||' - '||p_leg_name,'DRAFT',p_reversal_of,actor);
 FOR line IN SELECT value FROM jsonb_array_elements(p_leg->'lines') LOOP n:=n+10;
   INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,debit,credit,store_id,warehouse_id,customer_id,description)
   VALUES(c,journal_id,n,(line->>'accountId')::uuid,(line->>'debit')::numeric,(line->>'credit')::numeric,
     NULLIF(line->>'storeId','')::uuid,NULLIF(line->>'warehouseId','')::uuid,
     NULLIF(line->>'customerId','')::uuid,line->>'description');
 END LOOP;
 UPDATE public.finance_journals SET status='POSTED',posted_by=actor,posted_at=clock_timestamp()
 WHERE company_id=c AND id=journal_id RETURNING * INTO j;
 IF j.total_debit<=0 OR j.total_debit<>j.total_credit THEN RAISE EXCEPTION 'INVOICE_REVISION_JOURNAL_UNBALANCED'; END IF;
 UPDATE public.financial_events SET status='POSTED',processed_at=clock_timestamp() WHERE company_id=c AND id=event_id;
 RETURN journal_id;
END
$post$;
REVOKE ALL ON FUNCTION private.post_backoffice_invoice_revision_journal_leg(uuid,uuid,integer,text,jsonb,text,uuid)
 FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION private.execute_backoffice_invoice_revision(p_operation_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $execute$
DECLARE c uuid:=public.private_active_company_id();actor uuid:=auth.uid();prep private.backoffice_invoice_revision_preparations%rowtype;
 existing private.backoffice_invoice_revisions%rowtype;invoice public.backoffice_sales_invoices%rowtype;
 plan jsonb;revision_id uuid:=gen_random_uuid();revision_no bigint;ids jsonb:='[]'::jsonb;
  jid uuid;leg jsonb;n integer:=0;response jsonb;item jsonb;current_identity jsonb;
BEGIN
 IF actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
 SELECT * INTO prep FROM private.backoffice_invoice_revision_preparations p
  WHERE p.company_id=c AND p.operation_id=p_operation_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'INVOICE_REVISION_PREPARATION_NOT_FOUND'; END IF;
 SELECT * INTO existing FROM private.backoffice_invoice_revisions r
  WHERE r.company_id=c AND r.operation_id=p_operation_id;
 IF FOUND THEN RETURN existing.response_snapshot||jsonb_build_object('exactRetry',true); END IF;
 plan:=private.plan_backoffice_invoice_revision_journals(p_operation_id);
 SELECT * INTO STRICT invoice FROM public.backoffice_sales_invoices i
  WHERE i.company_id=c AND i.id=prep.invoice_id;
 SELECT COALESCE(max(r.revision_no),0)+1 INTO revision_no FROM private.backoffice_invoice_revisions r
  WHERE r.company_id=c AND r.invoice_id=invoice.id;
  current_identity:=private.backoffice_invoice_effective_identity(c,invoice.id,NULL);
  IF revision_no>1 AND ((current_identity->>'customerId')::uuid<>(prep.request_snapshot->>'customerId')::uuid
      OR (current_identity->>'invoiceDate')::date<>(prep.request_snapshot->>'invoiceDate')::date) THEN
    RAISE EXCEPTION 'INVOICE_REVISION_REPEAT_IDENTITY_OR_DATE_NOT_YET_SUPPORTED';
  END IF;
  jid:=private.post_backoffice_invoice_revision_journal_leg(invoice.id,revision_id,10,'RECOGNITION_REVERSAL',
    plan->'recognitionReversal','PRIOR_PERIOD_ADJUSTMENT',NULL);
  IF jid IS NOT NULL THEN ids:=ids||jsonb_build_array(jid); END IF;n:=10;
 jid:=private.post_backoffice_invoice_revision_journal_leg(invoice.id,revision_id,20,'RECOGNITION_REPLACEMENT',
    plan->'recognitionReplacement','AUTOMATIC',NULL);
  IF jid IS NOT NULL THEN ids:=ids||jsonb_build_array(jid); END IF;n:=20;
 FOR leg IN SELECT value FROM jsonb_array_elements(plan->'receiptJournalLegs') LOOP
   n:=n+10;jid:=private.post_backoffice_invoice_revision_journal_leg(invoice.id,revision_id,n,leg->>'leg',leg,'AUTOMATIC',NULL);
    IF jid IS NOT NULL THEN ids:=ids||jsonb_build_array(jid); END IF;
 END LOOP;
 FOR leg IN SELECT value FROM jsonb_array_elements(plan->'downPaymentJournalLegs') LOOP
   n:=n+10;jid:=private.post_backoffice_invoice_revision_journal_leg(invoice.id,revision_id,n,leg->>'leg',leg,'AUTOMATIC',NULL);
    IF jid IS NOT NULL THEN ids:=ids||jsonb_build_array(jid); END IF;
 END LOOP;
 IF jsonb_array_length(plan->'amountJournal'->'lines')>0 THEN
   n:=n+10;jid:=private.post_backoffice_invoice_revision_journal_leg(invoice.id,revision_id,n,'AMOUNT_DELTA',
      plan->'amountJournal','AUTOMATIC',NULL);
    IF jid IS NOT NULL THEN ids:=ids||jsonb_build_array(jid); END IF;
 END IF;
 response:=jsonb_build_object('status','POSTED','revisionId',revision_id,'revision',revision_no,
   'invoiceId',invoice.id,'customerId',prep.request_snapshot->>'customerId',
   'invoiceDate',prep.request_snapshot->>'invoiceDate','effectiveTotal',plan->'amounts'->>'afterTotal',
   'journalIds',ids,'exactRetry',false);
 INSERT INTO private.backoffice_invoice_revisions(company_id,id,operation_id,invoice_id,revision_no,
   prior_customer_id,new_customer_id,prior_invoice_date,new_invoice_date,payable_delta,source_snapshot,
   execution_plan,journal_ids,response_snapshot,actor_id,revision_date)
  VALUES(c,revision_id,p_operation_id,invoice.id,revision_no,(current_identity->>'customerId')::uuid,
    (prep.request_snapshot->>'customerId')::uuid,(current_identity->>'invoiceDate')::date,
   (prep.request_snapshot->>'invoiceDate')::date,(plan->'amounts'->>'payableDelta')::numeric,
    prep.source_snapshot,plan,ids,response,actor,
    (clock_timestamp() AT TIME ZONE (SELECT timezone FROM public.companies WHERE id=c))::date);
 INSERT INTO private.backoffice_invoice_revision_lines(company_id,revision_id,invoice_id,invoice_line_id,
   new_unit_price,new_discount_amount,before_amounts,after_amounts)
  SELECT c,revision_id,invoice.id,(element.value->>'invoiceLineId')::uuid,
    (element.value->'after'->>'enteredUnitPrice')::numeric,
    (element.value->'after'->>'discountAmount')::numeric,
    element.value->'before',element.value->'after'
  FROM jsonb_array_elements(plan->'amounts'->'lines') element(value);
  FOR item IN SELECT element.value FROM jsonb_array_elements(plan->'receipts') element(value) LOOP
   IF item->>'action' NOT IN('NO_EFFECT_CANCELED') THEN
    INSERT INTO private.backoffice_invoice_revision_settlement_attributions(company_id,revision_id,source_type,
      source_id,action,amount,from_customer_id,to_customer_id,source_snapshot)
    VALUES(c,revision_id,'RECEIPT_ALLOCATION',(item->>'allocationId')::uuid,item->>'action',
      (item->>'allocatedAmount')::numeric,(current_identity->>'customerId')::uuid,
      (prep.request_snapshot->>'customerId')::uuid,item);
   END IF;
 END LOOP;
  FOR item IN SELECT element.value FROM jsonb_array_elements(plan->'downPayments') element(value) LOOP
   IF item->>'action'='TRANSFER_POSTED_DP_ATTRIBUTION' THEN
    INSERT INTO private.backoffice_invoice_revision_settlement_attributions(company_id,revision_id,source_type,
      source_id,action,amount,from_customer_id,to_customer_id,source_snapshot)
    VALUES(c,revision_id,'DOWN_PAYMENT_APPLICATION',(item->>'applicationId')::uuid,item->>'action',
      (item->>'appliedAmount')::numeric,(item->>'fromCustomerId')::uuid,
      (prep.request_snapshot->>'customerId')::uuid,item);
   END IF;
 END LOOP;
 PERFORM private.reconcile_backoffice_invoice_receivable_schedule(c,invoice.id);
  FOR item IN SELECT element.value FROM jsonb_array_elements(plan->'dates'->'schedules') element(value) LOOP
   UPDATE public.backoffice_sales_invoice_receivable_schedules SET due_date=(item->>'dueDate')::date,
     updated_at=clock_timestamp() WHERE company_id=c AND id=(item->>'scheduleId')::uuid;
 END LOOP;
 RETURN response;
END
$execute$;
REVOKE ALL ON FUNCTION private.execute_backoffice_invoice_revision(uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION private.guard_legacy_invoice_price_correction_after_unified_revision()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $guard$
BEGIN
 IF EXISTS(SELECT 1 FROM private.backoffice_invoice_revisions r
   WHERE r.company_id=NEW.company_id AND r.invoice_id=NEW.source_invoice_id) THEN
  RAISE EXCEPTION 'LEGACY_PRICE_CORRECTION_AFTER_UNIFIED_REVISION_NOT_ALLOWED';
 END IF;
 RETURN NEW;
END
$guard$;
CREATE TRIGGER legacy_invoice_price_correction_unified_guard
BEFORE INSERT ON public.backoffice_sales_invoice_price_corrections FOR EACH ROW
EXECUTE FUNCTION private.guard_legacy_invoice_price_correction_after_unified_revision();
REVOKE ALL ON FUNCTION private.guard_legacy_invoice_price_correction_after_unified_revision()
 FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.post_backoffice_invoice_revision(p_command jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $rpc$
DECLARE prepared jsonb;
BEGIN
 prepared:=private.prepare_backoffice_invoice_revision(p_command);
 RETURN private.execute_backoffice_invoice_revision((p_command->>'operationId')::uuid);
END
$rpc$;
REVOKE ALL ON FUNCTION public.post_backoffice_invoice_revision(jsonb) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.post_backoffice_invoice_revision(jsonb) TO authenticated;

CREATE FUNCTION public.get_backoffice_invoice_revision_context(p_invoice_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $rpc$
DECLARE c uuid:=public.private_active_company_id();actor uuid:=auth.uid();invoice public.backoffice_sales_invoices%rowtype;
 identity jsonb;customer jsonb;history jsonb;lines jsonb;revision bigint;
BEGIN
 IF actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
 IF c IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
 PERFORM private.acp_require_permission_capability(c,'sales.backoffice_orders','VIEW');
 SELECT * INTO invoice FROM public.backoffice_sales_invoices i WHERE i.company_id=c AND i.id=p_invoice_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
 IF invoice.status<>'POSTED' OR invoice.invoice_type<>'REGULAR' THEN
  RAISE EXCEPTION 'POSTED_REGULAR_INVOICE_REQUIRED'; END IF;
 identity:=private.backoffice_invoice_effective_identity(c,invoice.id,NULL);
 SELECT jsonb_build_object('id',cu.id,'code',cu.code,'name',cu.name,'address',cu.address,
   'phone',cu.phone,'masterVersion',cu.master_version) INTO STRICT customer
 FROM public.customers cu WHERE cu.company_id=c AND cu.id=(identity->>'customerId')::uuid;
 SELECT count(*) INTO revision FROM public.backoffice_sales_invoice_price_corrections pc
  WHERE pc.company_id=c AND pc.source_invoice_id=invoice.id AND pc.status='POSTED';
 revision:=revision+(identity->>'revision')::bigint;
 SELECT COALESCE(jsonb_agg(jsonb_build_object('id',r.id,'revision',r.revision_no,
   'postedAt',r.posted_at,'revisionDate',r.revision_date,'actorId',r.actor_id,'priorCustomerId',r.prior_customer_id,
   'customerId',r.new_customer_id,'priorInvoiceDate',r.prior_invoice_date,
   'invoiceDate',r.new_invoice_date,'payableDelta',r.payable_delta,'journalIds',r.journal_ids)
   ORDER BY r.revision_no),'[]'::jsonb) INTO history
 FROM private.backoffice_invoice_revisions r WHERE r.company_id=c AND r.invoice_id=invoice.id;
 SELECT COALESCE(jsonb_agg(jsonb_build_object('invoiceLineId',l.id,'productId',l.product_id,
   'sku',p.sku,'productName',p.name,
   'quantityUom',l.quantity_uom,'uomCode',u.code,
   'effectiveAmounts',private.backoffice_invoice_effective_line_amounts(c,l.id)) ORDER BY l.line_no),'[]'::jsonb)
 INTO lines FROM public.backoffice_sales_invoice_lines l
 LEFT JOIN public.products p ON p.company_id=l.company_id AND p.id=l.product_id
 LEFT JOIN public.uoms u ON u.company_id=l.company_id AND u.id=l.uom_id
 WHERE l.company_id=c AND l.invoice_id=invoice.id
  AND l.line_type='PRODUCT' AND l.source_kind='SALES_ORDER';
 RETURN jsonb_build_object('invoiceId',invoice.id,'invoiceNo',invoice.invoice_no,
  'masterVersion',invoice.master_version,'revision',revision,'effectiveIdentity',identity,
  'customer',customer,'effectiveTotal',private.backoffice_invoice_effective_total(c,invoice.id,NULL),
  'lines',lines,'schedules',COALESCE((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.installment_no)
    FROM public.backoffice_sales_invoice_receivable_schedules s
    WHERE s.company_id=c AND s.invoice_id=invoice.id),'[]'::jsonb),
  'history',history,'canCorrect',NOT invoice.return_adjustment_pending_confirmation AND NOT EXISTS(
    SELECT 1 FROM public.backoffice_sales_credit_notes n WHERE n.company_id=c
      AND n.source_invoice_id=invoice.id AND n.status IN('DRAFT','POSTED')),
  'repeatIdentityOrDateChangeSupported',(identity->>'revision')::bigint=0);
END
$rpc$;
REVOKE ALL ON FUNCTION public.get_backoffice_invoice_revision_context(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.get_backoffice_invoice_revision_context(uuid) TO authenticated;
