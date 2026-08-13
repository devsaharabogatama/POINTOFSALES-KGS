-- G6 phase 8D: Goods Receipt, Supplier Invoice and Supplier Payment posting preflight.
-- SAFETY: one SELECT statement; no business state is changed.

WITH target_events AS MATERIALIZED (
  SELECT event.*
  FROM public.financial_events event
  WHERE event.status='HOLD'::public.event_status
    AND (event.system_event_key,event.event_type,event.source_table) IN (
      ('GOODS_RECEIPT','PURCHASE_POSTED'::public.event_type,
       'goods_receipt_documents'),
      ('SUPPLIER_INVOICE','SUPPLIER_INVOICE_VALIDATED'::public.event_type,
       'supplier_invoice_documents'),
      ('SUPPLIER_PAYMENT','SUPPLIER_PAYMENT_VALIDATED'::public.event_type,
       'supplier_payment_documents')
    )
),
receipt_source AS MATERIALIZED (
  SELECT event.company_id,event.id event_id,event.source_id,
    document.provisional_ap_total,
    COALESCE((SELECT sum(line.provisional_ap_amount)
      FROM public.goods_receipt_lines line
      WHERE line.company_id=document.company_id
        AND line.document_id=document.id),0) line_total,
    COALESCE((SELECT sum(batch.qty_purchased*batch.cogs_unit)
      FROM public.product_batches batch
      JOIN public.goods_receipt_condition_allocations allocation
        ON allocation.company_id=batch.company_id
       AND allocation.id=batch.goods_receipt_condition_allocation_id
      JOIN public.goods_receipt_lines line
        ON line.company_id=allocation.company_id
       AND line.id=allocation.receipt_line_id
      WHERE line.company_id=document.company_id
        AND line.document_id=document.id),0) batch_value,
    (event.amounts->>'inventoryDebit')::NUMERIC inventory_debit,
    (event.amounts->>'supplierApProvisionalCredit')::NUMERIC ap_credit,
    NULLIF(event.amounts->>'inventoryAccountId','')::UUID inventory_account_id,
    NULLIF(event.amounts->>'supplierApAccountId','')::UUID ap_account_id
  FROM target_events event
  JOIN public.goods_receipt_documents document
    ON document.company_id=event.company_id AND document.id=event.source_id
   AND document.status='POSTED' AND document.financial_event_id=event.id
  WHERE event.system_event_key='GOODS_RECEIPT'
),
invoice_source AS MATERIALIZED (
  SELECT event.company_id,event.id event_id,event.source_id,
    document.provisional_value_allocated,document.actual_value_allocated,
    document.purchase_price_variance,document.grand_total,
    COALESCE((SELECT sum(line.tax_amount)
      FROM public.supplier_invoice_lines line
      WHERE line.company_id=document.company_id
        AND line.document_id=document.id
        AND line.tax_is_recoverable_snapshot),0) recoverable_tax,
    COALESCE((SELECT sum(line.tax_amount)
      FROM public.supplier_invoice_lines line
      WHERE line.company_id=document.company_id
        AND line.document_id=document.id
        AND line.tax_is_recoverable_snapshot=FALSE),0) nonrecoverable_tax,
    COALESCE((SELECT sum(allocation.provisional_value)
      FROM public.supplier_invoice_allocations allocation
      WHERE allocation.company_id=document.company_id
        AND allocation.document_id=document.id),0) allocation_provisional,
    COALESCE((SELECT sum(allocation.actual_value)
      FROM public.supplier_invoice_allocations allocation
      WHERE allocation.company_id=document.company_id
        AND allocation.document_id=document.id),0) allocation_actual,
    (event.amounts->>'apProvisionalDebit')::NUMERIC event_ap_provisional,
    (event.amounts->>'apFinalCredit')::NUMERIC event_ap_final,
    (event.amounts->>'purchasePriceVariance')::NUMERIC event_variance,
    (event.amounts->>'recoverableInputTaxDebit')::NUMERIC event_recoverable_tax,
    (event.amounts->>'nonrecoverablePurchaseTax')::NUMERIC
      event_nonrecoverable_tax,
    NULLIF(event.amounts->>'apProvisionalAccountId','')::UUID
      ap_provisional_account_id,
    NULLIF(event.amounts->>'apFinalAccountId','')::UUID ap_final_account_id,
    NULLIF(event.amounts->>'purchasePriceVarianceAccountId','')::UUID
      variance_account_id,
    NULLIF(event.amounts->>'inputTaxAccountId','')::UUID input_tax_account_id
  FROM target_events event
  JOIN public.supplier_invoice_documents document
    ON document.company_id=event.company_id AND document.id=event.source_id
   AND document.status='VALIDATED' AND document.financial_event_id=event.id
  WHERE event.system_event_key='SUPPLIER_INVOICE'
),
payment_source AS MATERIALIZED (
  SELECT event.company_id,event.id event_id,event.source_id,
    document.total_amount,document.supplier_id,
    COALESCE((SELECT sum(allocation.allocated_amount)
      FROM public.supplier_payment_allocations allocation
      WHERE allocation.company_id=document.company_id
        AND allocation.document_id=document.id),0) allocation_total,
    (event.amounts->>'totalAmount')::NUMERIC event_total,
    NULLIF(event.amounts->>'apFinalDebitAccount','')::UUID
      ap_final_account_id,
    NULLIF(event.amounts->>'cashOrBankCreditAccount','')::UUID
      settlement_account_id
  FROM target_events event
  JOIN public.supplier_payment_documents document
    ON document.company_id=event.company_id AND document.id=event.source_id
   AND document.status='VALIDATED' AND document.financial_event_id=event.id
  WHERE event.system_event_key='SUPPLIER_PAYMENT'
),
account_snapshots AS MATERIALIZED (
  SELECT company_id,event_id,'INVENTORY_ASSET' function_key,
         inventory_account_id account_id,TRUE required
  FROM receipt_source
  UNION ALL SELECT company_id,event_id,'SUPPLIER_AP_PROVISIONAL',
         ap_account_id,TRUE FROM receipt_source
  UNION ALL SELECT company_id,event_id,'SUPPLIER_AP_PROVISIONAL',
         ap_provisional_account_id,TRUE FROM invoice_source
  UNION ALL SELECT company_id,event_id,'SUPPLIER_AP_FINAL',
         ap_final_account_id,TRUE FROM invoice_source
  UNION ALL SELECT company_id,event_id,'PURCHASE_PRICE_VARIANCE',
         variance_account_id,TRUE FROM invoice_source
  UNION ALL SELECT company_id,event_id,'INPUT_TAX',input_tax_account_id,
         recoverable_tax>0 FROM invoice_source
  UNION ALL SELECT company_id,event_id,'SUPPLIER_AP_FINAL',
         ap_final_account_id,TRUE FROM payment_source
  UNION ALL SELECT company_id,event_id,'PAYMENT_SOURCE',
         settlement_account_id,TRUE FROM payment_source
),
account_state AS MATERIALIZED (
  SELECT snapshot.*,
    account.id IS NOT NULL account_exists,
    COALESCE(account.is_active,FALSE) account_active,
    COALESCE(account.is_postable,FALSE) account_postable
  FROM account_snapshots snapshot
  LEFT JOIN public.chart_of_accounts account
    ON account.company_id=snapshot.company_id AND account.id=snapshot.account_id
),
checks(check_name,status,details) AS (
  SELECT 'purchase_ap_target_inventory','PASS',jsonb_build_object(
    'goodsReceiptEvents',(SELECT count(*) FROM receipt_source),
    'supplierInvoiceEvents',(SELECT count(*) FROM invoice_source),
    'supplierPaymentEvents',(SELECT count(*) FROM payment_source),
    'totalEvents',(SELECT count(*) FROM target_events))

  UNION ALL
  SELECT 'purchase_ap_event_source_linkage',
    CASE WHEN (SELECT count(*) FROM target_events)=
      ((SELECT count(*) FROM receipt_source)+
       (SELECT count(*) FROM invoice_source)+
       (SELECT count(*) FROM payment_source)) THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('targetEvents',(SELECT count(*) FROM target_events),
      'linkedFinalSources',((SELECT count(*) FROM receipt_source)+
       (SELECT count(*) FROM invoice_source)+
       (SELECT count(*) FROM payment_source)))

  UNION ALL
  SELECT 'goods_receipt_source_amount_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('receiptCount',(SELECT count(*) FROM receipt_source),
      'violationRows',count(*))
  FROM receipt_source
  WHERE inventory_debit IS NULL OR ap_credit IS NULL
     OR round(provisional_ap_total,4)<>round(line_total,4)
     OR round(provisional_ap_total,4)<>round(batch_value,4)
     OR round(provisional_ap_total,4)<>round(inventory_debit,4)
     OR round(provisional_ap_total,4)<>round(ap_credit,4)

  UNION ALL
  SELECT 'supplier_invoice_source_amount_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invoiceCount',(SELECT count(*) FROM invoice_source),
      'violationRows',count(*))
  FROM invoice_source
  WHERE event_ap_provisional IS NULL OR event_ap_final IS NULL
     OR event_variance IS NULL OR event_recoverable_tax IS NULL
     OR event_nonrecoverable_tax IS NULL
     OR round(provisional_value_allocated,4)<>round(allocation_provisional,4)
     OR round(actual_value_allocated,4)<>round(allocation_actual,4)
     OR round(purchase_price_variance,4)<>
          round(actual_value_allocated-provisional_value_allocated,4)
     OR round(grand_total,4)<>
          round(actual_value_allocated+recoverable_tax+nonrecoverable_tax,4)
     OR round(event_ap_provisional,4)<>round(provisional_value_allocated,4)
     OR round(event_ap_final,4)<>round(grand_total,4)
     OR round(event_variance,4)<>round(purchase_price_variance,4)
     OR round(event_recoverable_tax,4)<>round(recoverable_tax,4)
     OR round(event_nonrecoverable_tax,4)<>round(nonrecoverable_tax,4)
     OR round(event_ap_provisional+event_variance+event_recoverable_tax+
              event_nonrecoverable_tax,4)<>round(event_ap_final,4)

  UNION ALL
  SELECT 'supplier_payment_source_amount_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('paymentCount',(SELECT count(*) FROM payment_source),
      'violationRows',count(*))
  FROM payment_source
  WHERE event_total IS NULL
     OR round(total_amount,4)<>round(allocation_total,4)
     OR round(total_amount,4)<>round(event_total,4)

  UNION ALL
  SELECT 'supplier_payment_allocation_source_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('violationRows',count(*))
  FROM payment_source payment
  JOIN public.supplier_payment_allocations allocation
    ON allocation.company_id=payment.company_id
   AND allocation.document_id=payment.source_id
  LEFT JOIN public.supplier_invoice_documents invoice
    ON invoice.company_id=allocation.company_id
   AND invoice.id=allocation.invoice_id
   AND invoice.status='VALIDATED'
   AND invoice.supplier_id=payment.supplier_id
  WHERE invoice.id IS NULL

  UNION ALL
  SELECT 'purchase_ap_account_snapshot_readiness',
    CASE WHEN count(*) FILTER(WHERE required AND
      (account_id IS NULL OR NOT account_exists OR NOT account_active OR
       NOT account_postable))=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('requiredRows',count(*) FILTER(WHERE required),
      'invalidRows',count(*) FILTER(WHERE required AND
       (account_id IS NULL OR NOT account_exists OR NOT account_active OR
        NOT account_postable)),
      'functions',COALESCE(jsonb_agg(DISTINCT function_key) FILTER(WHERE
       required AND (account_id IS NULL OR NOT account_exists OR
       NOT account_active OR NOT account_postable)),'[]'))
  FROM account_state

  UNION ALL
  SELECT 'purchase_ap_existing_journal_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('journalCount',count(*))
  FROM public.finance_journals journal
  JOIN target_events event ON event.company_id=journal.company_id
   AND event.id=journal.financial_event_id

  UNION ALL
  SELECT 'purchase_ap_posting_runtime','SETUP',jsonb_build_object(
    'targetContracts',ARRAY[
      'GOODS_RECEIPT','SUPPLIER_INVOICE','SUPPLIER_PAYMENT'],
    'historicalEvents',(SELECT count(*) FROM target_events),
    'requiredMigrationCapabilities',jsonb_build_array(
      'immutable source account snapshots',
      'Goods Receipt inventory and AP provisional',
      'Supplier Invoice AP reclassification tax and signed variance',
      'Supplier Payment AP settlement',
      'exact idempotent event-to-journal identity'))
)
SELECT check_name,status,details FROM checks ORDER BY CASE status
  WHEN 'BLOCKER' THEN 1 WHEN 'BACKFILL' THEN 2 WHEN 'SETUP' THEN 3 ELSE 4 END,
  check_name;
