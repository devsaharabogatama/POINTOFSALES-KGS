-- SELECT ONLY: compares legacy column projections against user-supplied Production baseline.
-- Additive columns excluded using the supplied pre-migration catalog, not guessed names.
-- REVIEW means data/row count changed; distinguish approved backfill vs operational writes.
-- No mutation, application RPC, secret or transaction contents returned.
WITH baseline(table_name,column_names,expected_rows,expected_digest) AS (VALUES
  ('sales_headers',ARRAY['id','invoice_no','session_id','customer_id','transaction_date','is_tempo','due_date','sj_required','sj_no','sj_status','so_confirm_status','invoice_status','subtotal','item_discount','global_discount','grand_total','paid_amount','sisa_piutang','payment_status','financial_status','recon_status','created_by','is_revision','original_invoice_no','payload_snapshot','created_at','company_id','store_id','pos_id','document_status','client_transaction_id','posting_idempotency_key','sales_warehouse_id','posted_session_id','draft_reason','blocker_snapshot','grand_total_before_rounding','rounding_direction','rounding_increment','rounding_adjustment','grand_total_after_rounding','receipt_snapshot','master_version','updated_at','posted_at','posted_by','draft_no','draft_label','draft_notes','created_session_id','edit_lock_owner_id','edit_lock_session_id','edit_lock_acquired_at','edit_lock_heartbeat_at','canceled_at','canceled_by','cancel_reason','source_channel','offline_submission_id','offline_transaction_at','offline_price_variance_total','fulfillment_mode','delivery_recipient_name','delivery_recipient_phone','delivery_address','delivery_scheduled_at','delivery_notes','delivery_fee_amount','delivery_fee_invoice_display_mode','transaction_date_source','transaction_date_selected_by','transaction_date_selected_at','planned_order_date','order_timing_mode','planned_order_selected_by','planned_order_selected_at','scheduled_activated_at','order_runtime_status','confirmed_at','confirmed_by','confirmation_idempotency_key','reservation_version']::text[],278::bigint,'8a34655097917f4da5a8cea14e889968'),
  ('sales_details',ARRAY['id','sales_id','product_id','warehouse_id','qty','price','discount_amount','subtotal','cogs_unit','cogs_total','company_id','base_unit_price','pricelist_id','pricelist_rule_id','resolved_unit_price','line_discount_type','line_discount_input','line_discount_amount','allocated_order_discount_amount','unit_price_after_discount','line_total','pricing_resolved_at','tax_rule_id','tax_rule_version','tax_code_snapshot','tax_name_snapshot','tax_scope_snapshot','tax_rate_percent_snapshot','tax_price_mode_snapshot','tax_calculation_scope_snapshot','tax_base','tax_amount','tax_rounding','tax_account_id','tax_account_code_snapshot','tax_account_name_snapshot','client_line_key','product_uom_id','sale_uom_id','sale_uom_name_snapshot','uom_factor_to_base_snapshot','quantity_base','product_sku_snapshot','product_name_snapshot','allocated_document_rounding','fifo_cost_total','offline_snapshot_unit_price','offline_resolved_unit_price','offline_price_variance','canonical_resolved_unit_price','price_override_applied','price_override_unit_price','price_override_actor_id','price_override_terminal_id','price_override_session_id','price_override_source','price_override_resolved_at']::text[],693::bigint,'b102e8cd15acfc28d5068f65c109724b'),
  ('supplier_order_documents',ARRAY['id','company_id','order_no','store_id','destination_warehouse_id','supplier_id','order_date','expected_date','ordered_by','status','notes','cancellation_reason','line_count','total_ordered_base_qty','estimated_total','confirmed_by','confirmed_at','confirmation_idempotency_key','canceled_by','canceled_at','master_version','created_at','updated_at']::text[],56::bigint,'162b132c973261f06a34ecdcc2366051'),
  ('supplier_order_lines',ARRAY['id','company_id','document_id','line_no','client_line_key','product_id','ordered_uom_id','ordered_qty','factor_to_base_snapshot','ordered_base_qty','estimated_unit_price','estimated_subtotal','product_sku_snapshot','product_name_snapshot','ordered_uom_name_snapshot','supplier_product_code_snapshot','created_at']::text[],387::bigint,'a94a714303720451a2742cfbb48fa734'),
  ('goods_receipt_documents',ARRAY['id','company_id','receipt_no','supplier_order_id','store_id','warehouse_id','receiving_session_id','receiving_pos_id','received_by','received_at','supplier_delivery_no','notes','status','line_count','received_total_base_qty','accepted_total_base_qty','damaged_total_base_qty','rejected_total_base_qty','provisional_ap_total','has_over_receipt','posting_idempotency_key','financial_event_id','posted_by','posted_at','canceled_by','canceled_at','master_version','created_at','updated_at','source_channel']::text[],48::bigint,'f4ef837da397399043b63c24fe99bf12'),
  ('goods_receipt_lines',ARRAY['id','company_id','document_id','line_no','client_line_key','supplier_order_line_id','product_id','received_uom_id','received_qty','factor_to_base_snapshot','received_base_qty','accepted_good_qty','damaged_qty','rejected_qty','accepted_good_base_qty','damaged_base_qty','rejected_base_qty','estimated_unit_price_snapshot','estimated_base_unit_cost','provisional_ap_amount','is_over_received','over_received_base_qty','product_sku_snapshot','product_name_snapshot','received_uom_name_snapshot','base_uom_id','base_uom_name_snapshot','created_at']::text[],307::bigint,'05f94fb1ae3ab27552b84dc7e676d180'),
  ('purchase_return_documents',ARRAY['id','company_id','return_no','source_receipt_id','supplier_order_id','supplier_id','store_id','source_warehouse_id','created_session_id','created_pos_id','return_date','return_reason','supplier_document_no','notes','status','review_status','line_count','total_return_base_qty','provisional_ap_adjustment_total','created_by','reviewed_by','reviewed_at','review_reason','handed_over_at','posting_idempotency_key','financial_event_id','posted_by','posted_at','canceled_by','canceled_at','cancel_reason','master_version','created_at','updated_at']::text[],0::bigint,'d41d8cd98f00b204e9800998ecf8427e'),
  ('supplier_invoice_documents',ARRAY['id','company_id','invoice_no','supplier_invoice_no','supplier_id','invoice_date','due_date','price_mode','status','matching_status','line_count','invoice_total_base_qty','allocated_total_base_qty','subtotal_before_tax','tax_total','grand_total','provisional_value_allocated','actual_value_allocated','purchase_price_variance','tolerance_policy_id','tolerance_policy_version','notes','evidence_url','validation_idempotency_key','financial_event_id','created_by','validated_by','validated_at','canceled_by','canceled_at','cancel_reason','master_version','created_at','updated_at']::text[],4::bigint,'0a615df9fc202a22ae2569c6973ff88b'),
  ('supplier_payment_documents',ARRAY['id','company_id','payment_no','supplier_id','payment_date','payment_method','source_account_id','supplier_bank_name','supplier_bank_account_no','supplier_bank_account_holder','reference_no','total_amount','notes','evidence_url','status','validation_idempotency_key','financial_event_id','created_by','validated_by','validated_at','canceled_by','canceled_at','cancel_reason','master_version','created_at','updated_at']::text[],2::bigint,'073cc0718a195f9d938a81081a591ab7'),
  ('stock_movements',ARRAY['id','product_id','warehouse_id','qty_change','movement_type','reference_table','reference_id','created_at','company_id','store_id','base_uom_id','base_uom_name_snapshot','balance_after_base_qty','actor_id','posted_at','movement_status','source_line_id','notes']::text[],615::bigint,'8a78b25ee11606e5d994dfbed4c04361'),
  ('product_stocks',ARRAY['id','product_id','warehouse_id','stock_qty','updated_at','company_id']::text[],78::bigint,'cdafc5143130cd0b5377dbe439804bba'),
  ('product_batches',ARRAY['id','product_id','warehouse_id','purchase_detail_id','qty_purchased','qty_remaining','cogs_unit','created_at','company_id','opening_stock_line_id','stock_transfer_line_id','source_batch_id','stock_adjustment_line_id','sales_return_line_id','goods_receipt_line_id','supplier_order_line_id','goods_receipt_condition_allocation_id']::text[],13::bigint,'b07e789ce17764d256e047b33623ea4e'),
  ('financial_events',ARRAY['id','event_code','event_type','source_table','source_id','root_sales_id','event_date','event_version','idempotency_key','payment_method','amounts','status','error_message','processed_at','created_by','created_at','company_id','store_id','system_event_key','transaction_category_id','transaction_rule_version']::text[],259::bigint,'4a4aaff0ffbdcba88279d806980aacbb'),
  ('finance_journals',ARRAY['id','company_id','journal_no','journal_type','accounting_period_id','accounting_date','original_event_date','source_type','source_id','source_version','financial_event_id','idempotency_key','system_event_key','transaction_category_id','transaction_rule_version','store_id','warehouse_id','currency_code','description','status','total_debit','total_credit','reversal_of_journal_id','master_version','created_by','posted_by','canceled_by','created_at','updated_at','posted_at','canceled_at','cancel_reason','display_no']::text[],40::bigint,'9959a4f7ee856b040a2a7e9398dc9491'),
  ('finance_journal_lines',ARRAY['id','company_id','journal_id','line_no','account_id','account_code_snapshot','account_name_snapshot','account_function_key_snapshot','normal_balance_snapshot','debit','credit','store_id','warehouse_id','customer_id','supplier_id','description','created_at']::text[],127::bigint,'e8deaf5afbc42d24a5c1b8e1583971b9'),
  ('cashier_sessions',ARRAY['id','session_code','cashier_id','opened_at','closed_at','opening_balance','expected_cash','actual_cash','difference','note_open','note_close','status','company_id','store_id','pos_id','sales_warehouse_id','opening_cash_actual','closing_cash_actual','opening_stock_snapshot_at','closing_stock_snapshot_at','master_version','updated_at']::text[],103::bigint,'ff5d3522c620927bc5988520b2168dfc'),
  ('customer_receipt_documents',ARRAY['id','company_id','receipt_no','customer_id','receipt_date','payment_method_id','payment_method_name_snapshot','payment_method_type_snapshot','settlement_route_snapshot','receipt_account_function_snapshot','receipt_account_id_snapshot','receivable_account_id_snapshot','reference_no','evidence_url','notes','total_amount','status','posting_idempotency_key','financial_event_id','master_version','created_by','posted_by','posted_at','canceled_by','canceled_at','cancel_reason','created_at','updated_at','received_amount','unapplied_amount','unapplied_disposition','customer_balance_ledger_entry_id','advance_liability_account_id_snapshot']::text[],0::bigint,'d41d8cd98f00b204e9800998ecf8427e')
), projected AS (
  SELECT 'sales_headers'::text table_name,
    to_jsonb(source) - ARRAY(SELECT field FROM jsonb_object_keys(to_jsonb(source)) fields(field)
      WHERE NOT EXISTS(SELECT 1 FROM baseline,unnest(column_names) names(name)
        WHERE table_name='sales_headers' AND names.name=field)) legacy_row
  FROM public.sales_headers source
  UNION ALL
  SELECT 'sales_details'::text table_name,
    to_jsonb(source) - ARRAY(SELECT field FROM jsonb_object_keys(to_jsonb(source)) fields(field)
      WHERE NOT EXISTS(SELECT 1 FROM baseline,unnest(column_names) names(name)
        WHERE table_name='sales_details' AND names.name=field)) legacy_row
  FROM public.sales_details source
  UNION ALL
  SELECT 'supplier_order_documents'::text table_name,
    to_jsonb(source) - ARRAY(SELECT field FROM jsonb_object_keys(to_jsonb(source)) fields(field)
      WHERE NOT EXISTS(SELECT 1 FROM baseline,unnest(column_names) names(name)
        WHERE table_name='supplier_order_documents' AND names.name=field)) legacy_row
  FROM public.supplier_order_documents source
  UNION ALL
  SELECT 'supplier_order_lines'::text table_name,
    to_jsonb(source) - ARRAY(SELECT field FROM jsonb_object_keys(to_jsonb(source)) fields(field)
      WHERE NOT EXISTS(SELECT 1 FROM baseline,unnest(column_names) names(name)
        WHERE table_name='supplier_order_lines' AND names.name=field)) legacy_row
  FROM public.supplier_order_lines source
  UNION ALL
  SELECT 'goods_receipt_documents'::text table_name,
    to_jsonb(source) - ARRAY(SELECT field FROM jsonb_object_keys(to_jsonb(source)) fields(field)
      WHERE NOT EXISTS(SELECT 1 FROM baseline,unnest(column_names) names(name)
        WHERE table_name='goods_receipt_documents' AND names.name=field)) legacy_row
  FROM public.goods_receipt_documents source
  UNION ALL
  SELECT 'goods_receipt_lines'::text table_name,
    to_jsonb(source) - ARRAY(SELECT field FROM jsonb_object_keys(to_jsonb(source)) fields(field)
      WHERE NOT EXISTS(SELECT 1 FROM baseline,unnest(column_names) names(name)
        WHERE table_name='goods_receipt_lines' AND names.name=field)) legacy_row
  FROM public.goods_receipt_lines source
  UNION ALL
  SELECT 'purchase_return_documents'::text table_name,
    to_jsonb(source) - ARRAY(SELECT field FROM jsonb_object_keys(to_jsonb(source)) fields(field)
      WHERE NOT EXISTS(SELECT 1 FROM baseline,unnest(column_names) names(name)
        WHERE table_name='purchase_return_documents' AND names.name=field)) legacy_row
  FROM public.purchase_return_documents source
  UNION ALL
  SELECT 'supplier_invoice_documents'::text table_name,
    to_jsonb(source) - ARRAY(SELECT field FROM jsonb_object_keys(to_jsonb(source)) fields(field)
      WHERE NOT EXISTS(SELECT 1 FROM baseline,unnest(column_names) names(name)
        WHERE table_name='supplier_invoice_documents' AND names.name=field)) legacy_row
  FROM public.supplier_invoice_documents source
  UNION ALL
  SELECT 'supplier_payment_documents'::text table_name,
    to_jsonb(source) - ARRAY(SELECT field FROM jsonb_object_keys(to_jsonb(source)) fields(field)
      WHERE NOT EXISTS(SELECT 1 FROM baseline,unnest(column_names) names(name)
        WHERE table_name='supplier_payment_documents' AND names.name=field)) legacy_row
  FROM public.supplier_payment_documents source
  UNION ALL
  SELECT 'stock_movements'::text table_name,
    to_jsonb(source) - ARRAY(SELECT field FROM jsonb_object_keys(to_jsonb(source)) fields(field)
      WHERE NOT EXISTS(SELECT 1 FROM baseline,unnest(column_names) names(name)
        WHERE table_name='stock_movements' AND names.name=field)) legacy_row
  FROM public.stock_movements source
  UNION ALL
  SELECT 'product_stocks'::text table_name,
    to_jsonb(source) - ARRAY(SELECT field FROM jsonb_object_keys(to_jsonb(source)) fields(field)
      WHERE NOT EXISTS(SELECT 1 FROM baseline,unnest(column_names) names(name)
        WHERE table_name='product_stocks' AND names.name=field)) legacy_row
  FROM public.product_stocks source
  UNION ALL
  SELECT 'product_batches'::text table_name,
    to_jsonb(source) - ARRAY(SELECT field FROM jsonb_object_keys(to_jsonb(source)) fields(field)
      WHERE NOT EXISTS(SELECT 1 FROM baseline,unnest(column_names) names(name)
        WHERE table_name='product_batches' AND names.name=field)) legacy_row
  FROM public.product_batches source
  UNION ALL
  SELECT 'financial_events'::text table_name,
    to_jsonb(source) - ARRAY(SELECT field FROM jsonb_object_keys(to_jsonb(source)) fields(field)
      WHERE NOT EXISTS(SELECT 1 FROM baseline,unnest(column_names) names(name)
        WHERE table_name='financial_events' AND names.name=field)) legacy_row
  FROM public.financial_events source
  UNION ALL
  SELECT 'finance_journals'::text table_name,
    to_jsonb(source) - ARRAY(SELECT field FROM jsonb_object_keys(to_jsonb(source)) fields(field)
      WHERE NOT EXISTS(SELECT 1 FROM baseline,unnest(column_names) names(name)
        WHERE table_name='finance_journals' AND names.name=field)) legacy_row
  FROM public.finance_journals source
  UNION ALL
  SELECT 'finance_journal_lines'::text table_name,
    to_jsonb(source) - ARRAY(SELECT field FROM jsonb_object_keys(to_jsonb(source)) fields(field)
      WHERE NOT EXISTS(SELECT 1 FROM baseline,unnest(column_names) names(name)
        WHERE table_name='finance_journal_lines' AND names.name=field)) legacy_row
  FROM public.finance_journal_lines source
  UNION ALL
  SELECT 'cashier_sessions'::text table_name,
    to_jsonb(source) - ARRAY(SELECT field FROM jsonb_object_keys(to_jsonb(source)) fields(field)
      WHERE NOT EXISTS(SELECT 1 FROM baseline,unnest(column_names) names(name)
        WHERE table_name='cashier_sessions' AND names.name=field)) legacy_row
  FROM public.cashier_sessions source
  UNION ALL
  SELECT 'customer_receipt_documents'::text table_name,
    to_jsonb(source) - ARRAY(SELECT field FROM jsonb_object_keys(to_jsonb(source)) fields(field)
      WHERE NOT EXISTS(SELECT 1 FROM baseline,unnest(column_names) names(name)
        WHERE table_name='customer_receipt_documents' AND names.name=field)) legacy_row
  FROM public.customer_receipt_documents source
), actual AS (
  SELECT table_name,count(*)::bigint actual_rows,
    md5(COALESCE(string_agg(legacy_row::text,E'\n' ORDER BY legacy_row::text),'')) actual_digest
  FROM projected GROUP BY table_name
), checks AS (
  SELECT baseline.*,
    COALESCE(actual.actual_rows,0) actual_rows,
    COALESCE(actual.actual_digest,md5('')) actual_digest,
    ARRAY(SELECT column_name FROM unnest(baseline.column_names) names(column_name)
      WHERE NOT EXISTS(SELECT 1 FROM pg_attribute attribute
        WHERE attribute.attrelid=to_regclass('public.'||baseline.table_name)
          AND attribute.attname=names.column_name AND attribute.attnum>0 AND NOT attribute.attisdropped)) missing_legacy_columns
  FROM baseline LEFT JOIN actual USING(table_name)
)
SELECT table_name,
  CASE WHEN cardinality(missing_legacy_columns)>0 THEN 'BLOCKER'
    WHEN expected_rows=actual_rows AND expected_digest=actual_digest THEN 'PASS' ELSE 'REVIEW' END status,
  expected_rows,actual_rows,expected_digest,actual_digest,missing_legacy_columns,
  'Whole baseline legacy values; mismatches require analysis, not deletion/reset or automatic fresh clone'::text interpretation
FROM checks ORDER BY table_name;
