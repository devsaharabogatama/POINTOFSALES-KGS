-- SELECT-only follow-up for the six growing/mutable REVIEW tables.
-- Impact: diagnostics only; no RPC/writer, stock/FIFO/reservation/payment/Finance mutation.
-- Candidate selection is chronological, NOT a stored baseline ID set.
-- Only exact legacy digest equality supports unchanged candidate values.
-- A mismatch is REVIEW, never permission to reset/delete or blame migration.
-- Stock quantities before rollout were not captured individually; no invented stock proof.
WITH baseline(table_name,column_names,expected_rows,expected_digest) AS (VALUES
('sales_headers',ARRAY['id','invoice_no','session_id','customer_id','transaction_date','is_tempo','due_date','sj_required','sj_no','sj_status','so_confirm_status','invoice_status','subtotal','item_discount','global_discount','grand_total','paid_amount','sisa_piutang','payment_status','financial_status','recon_status','created_by','is_revision','original_invoice_no','payload_snapshot','created_at','company_id','store_id','pos_id','document_status','client_transaction_id','posting_idempotency_key','sales_warehouse_id','posted_session_id','draft_reason','blocker_snapshot','grand_total_before_rounding','rounding_direction','rounding_increment','rounding_adjustment','grand_total_after_rounding','receipt_snapshot','master_version','updated_at','posted_at','posted_by','draft_no','draft_label','draft_notes','created_session_id','edit_lock_owner_id','edit_lock_session_id','edit_lock_acquired_at','edit_lock_heartbeat_at','canceled_at','canceled_by','cancel_reason','source_channel','offline_submission_id','offline_transaction_at','offline_price_variance_total','fulfillment_mode','delivery_recipient_name','delivery_recipient_phone','delivery_address','delivery_scheduled_at','delivery_notes','delivery_fee_amount','delivery_fee_invoice_display_mode','transaction_date_source','transaction_date_selected_by','transaction_date_selected_at','planned_order_date','order_timing_mode','planned_order_selected_by','planned_order_selected_at','scheduled_activated_at','order_runtime_status','confirmed_at','confirmed_by','confirmation_idempotency_key','reservation_version']::text[],278::bigint,'8a34655097917f4da5a8cea14e889968'),
('sales_details',ARRAY['id','sales_id','product_id','warehouse_id','qty','price','discount_amount','subtotal','cogs_unit','cogs_total','company_id','base_unit_price','pricelist_id','pricelist_rule_id','resolved_unit_price','line_discount_type','line_discount_input','line_discount_amount','allocated_order_discount_amount','unit_price_after_discount','line_total','pricing_resolved_at','tax_rule_id','tax_rule_version','tax_code_snapshot','tax_name_snapshot','tax_scope_snapshot','tax_rate_percent_snapshot','tax_price_mode_snapshot','tax_calculation_scope_snapshot','tax_base','tax_amount','tax_rounding','tax_account_id','tax_account_code_snapshot','tax_account_name_snapshot','client_line_key','product_uom_id','sale_uom_id','sale_uom_name_snapshot','uom_factor_to_base_snapshot','quantity_base','product_sku_snapshot','product_name_snapshot','allocated_document_rounding','fifo_cost_total','offline_snapshot_unit_price','offline_resolved_unit_price','offline_price_variance','canonical_resolved_unit_price','price_override_applied','price_override_unit_price','price_override_actor_id','price_override_terminal_id','price_override_session_id','price_override_source','price_override_resolved_at']::text[],693::bigint,'b102e8cd15acfc28d5068f65c109724b'),
('stock_movements',ARRAY['id','product_id','warehouse_id','qty_change','movement_type','reference_table','reference_id','created_at','company_id','store_id','base_uom_id','base_uom_name_snapshot','balance_after_base_qty','actor_id','posted_at','movement_status','source_line_id','notes']::text[],615::bigint,'8a78b25ee11606e5d994dfbed4c04361'),
('product_stocks',ARRAY['id','product_id','warehouse_id','stock_qty','updated_at','company_id']::text[],78::bigint,'cdafc5143130cd0b5377dbe439804bba'),
('financial_events',ARRAY['id','event_code','event_type','source_table','source_id','root_sales_id','event_date','event_version','idempotency_key','payment_method','amounts','status','error_message','processed_at','created_by','created_at','company_id','store_id','system_event_key','transaction_category_id','transaction_rule_version']::text[],259::bigint,'4a4aaff0ffbdcba88279d806980aacbb'),
('cashier_sessions',ARRAY['id','session_code','cashier_id','opened_at','closed_at','opening_balance','expected_cash','actual_cash','difference','note_open','note_close','status','company_id','store_id','pos_id','sales_warehouse_id','opening_cash_actual','closing_cash_actual','opening_stock_snapshot_at','closing_stock_snapshot_at','master_version','updated_at']::text[],103::bigint,'ff5d3522c620927bc5988520b2168dfc')
), raw_rows AS (
SELECT 'sales_headers'::text table_name,source.id,source.created_at chronology,
 to_jsonb(source) raw_row,
 jsonb_build_object('id',to_jsonb(source)->'id','company_id',to_jsonb(source)->'company_id','invoice_no',to_jsonb(source)->'invoice_no','draft_no',to_jsonb(source)->'draft_no','created_at',to_jsonb(source)->'created_at','transaction_date',to_jsonb(source)->'transaction_date','updated_at',to_jsonb(source)->'updated_at','document_status',to_jsonb(source)->'document_status','grand_total',to_jsonb(source)->'grand_total','session_id',to_jsonb(source)->'session_id') trace
 FROM public.sales_headers source
UNION ALL
SELECT 'sales_details'::text table_name,source.id,parent.created_at chronology,
 to_jsonb(source) raw_row,
 jsonb_build_object('id',to_jsonb(source)->'id','company_id',to_jsonb(source)->'company_id','sales_id',to_jsonb(source)->'sales_id','product_id',to_jsonb(source)->'product_id','warehouse_id',to_jsonb(source)->'warehouse_id','qty',to_jsonb(source)->'qty','quantity_base',to_jsonb(source)->'quantity_base','subtotal',to_jsonb(source)->'subtotal') trace
 FROM public.sales_details source LEFT JOIN public.sales_headers parent ON parent.id=source.sales_id AND parent.company_id=source.company_id
UNION ALL
SELECT 'stock_movements'::text table_name,source.id,source.created_at chronology,
 to_jsonb(source) raw_row,
 jsonb_build_object('id',to_jsonb(source)->'id','company_id',to_jsonb(source)->'company_id','product_id',to_jsonb(source)->'product_id','warehouse_id',to_jsonb(source)->'warehouse_id','qty_change',to_jsonb(source)->'qty_change','reference_table',to_jsonb(source)->'reference_table','reference_id',to_jsonb(source)->'reference_id','source_line_id',to_jsonb(source)->'source_line_id','created_at',to_jsonb(source)->'created_at','posted_at',to_jsonb(source)->'posted_at','balance_after_base_qty',to_jsonb(source)->'balance_after_base_qty','movement_type',to_jsonb(source)->'movement_type','movement_status',to_jsonb(source)->'movement_status') trace
 FROM public.stock_movements source
UNION ALL
SELECT 'product_stocks'::text table_name,source.id,NULL::timestamptz chronology,
 to_jsonb(source) raw_row,
 jsonb_build_object('id',to_jsonb(source)->'id','company_id',to_jsonb(source)->'company_id','product_id',to_jsonb(source)->'product_id','warehouse_id',to_jsonb(source)->'warehouse_id','stock_qty',to_jsonb(source)->'stock_qty','updated_at',to_jsonb(source)->'updated_at') trace
 FROM public.product_stocks source
UNION ALL
SELECT 'financial_events'::text table_name,source.id,source.created_at chronology,
 to_jsonb(source) raw_row,
 jsonb_build_object('id',to_jsonb(source)->'id','company_id',to_jsonb(source)->'company_id','event_code',to_jsonb(source)->'event_code','source_table',to_jsonb(source)->'source_table','source_id',to_jsonb(source)->'source_id','root_sales_id',to_jsonb(source)->'root_sales_id','system_event_key',to_jsonb(source)->'system_event_key','event_date',to_jsonb(source)->'event_date','created_at',to_jsonb(source)->'created_at','status',to_jsonb(source)->'status') trace
 FROM public.financial_events source
UNION ALL
SELECT 'cashier_sessions'::text table_name,source.id,source.opened_at chronology,
 to_jsonb(source) raw_row,
 jsonb_build_object('id',to_jsonb(source)->'id','company_id',to_jsonb(source)->'company_id','session_code',to_jsonb(source)->'session_code','opened_at',to_jsonb(source)->'opened_at','closed_at',to_jsonb(source)->'closed_at','status',to_jsonb(source)->'status','updated_at',to_jsonb(source)->'updated_at') trace
 FROM public.cashier_sessions source
), projected AS (
 SELECT raw_rows.*, raw_row-ARRAY(
 SELECT field FROM jsonb_object_keys(raw_row) fields(field)
 WHERE NOT EXISTS(SELECT 1 FROM unnest(b.column_names) names(name) WHERE names.name=field)
 ) legacy_row,b.expected_rows,b.expected_digest
 FROM raw_rows JOIN baseline b USING(table_name)
), ranked AS (
 SELECT projected.*,row_number() OVER(PARTITION BY table_name ORDER BY chronology NULLS LAST,id) candidate_no
 FROM projected
), stats AS (
 SELECT table_name,count(*) actual_rows,
 count(*) FILTER(WHERE candidate_no<=expected_rows) candidate_rows,
 md5(COALESCE(string_agg(legacy_row::text,E'\n' ORDER BY legacy_row::text)
 FILTER(WHERE candidate_no<=expected_rows),'')) candidate_digest,
 count(*) FILTER(WHERE candidate_no>expected_rows) additional_rows,
 min(chronology) FILTER(WHERE candidate_no>expected_rows) first_additional_at,
 max(chronology) FILTER(WHERE candidate_no<=expected_rows) candidate_last_at,
 COALESCE(jsonb_agg(trace ORDER BY candidate_no)
 FILTER(WHERE candidate_no>expected_rows AND candidate_no<=expected_rows+200),'[]'::jsonb) additional_trace,
 COALESCE(jsonb_agg(trace ORDER BY candidate_no)
 FILTER(WHERE table_name='product_stocks' AND candidate_no<=200),'[]'::jsonb) current_stock_trace
 FROM ranked GROUP BY table_name
), missing AS (
 SELECT b.table_name,COALESCE(jsonb_agg(names.name)
 FILTER(WHERE attribute.attname IS NULL),'[]'::jsonb) missing_columns
 FROM baseline b CROSS JOIN LATERAL unnest(b.column_names) names(name)
 LEFT JOIN pg_attribute attribute ON attribute.attrelid=to_regclass('public.'||b.table_name)
 AND attribute.attname=names.name AND attribute.attnum>0 AND NOT attribute.attisdropped
 GROUP BY b.table_name
)
SELECT b.table_name,
 CASE WHEN missing_columns<>'[]'::jsonb THEN 'BLOCKER'
 WHEN b.table_name='product_stocks' THEN 'REVIEW'
 WHEN COALESCE(s.candidate_rows,0)=b.expected_rows AND s.candidate_digest=b.expected_digest
 THEN 'PASS' ELSE 'REVIEW' END status,
 jsonb_build_object('expectedRows',b.expected_rows,'actualRows',COALESCE(s.actual_rows,0),
 'candidateRows',COALESCE(s.candidate_rows,0),'expectedDigest',b.expected_digest,
 'candidateDigest',s.candidate_digest,'missingLegacyColumns',missing_columns,
 'additionalRows',COALESCE(s.additional_rows,0),'firstAdditionalAt',first_additional_at,
 'candidateLastAt',candidate_last_at,'additionalTrace',COALESCE(additional_trace,'[]'::jsonb),
 'additionalTraceTruncated',COALESCE(s.additional_rows,0)>200,
 'currentStockTrace',COALESCE(current_stock_trace,'[]'::jsonb),
 'limitation',CASE WHEN b.table_name='product_stocks'
 THEN 'No per-product baseline quantities available; stock trace is current inventory, NOT a proven delta reconciliation'
 ELSE 'Earliest expected count is a candidate subset, not captured baseline IDs. Exact digest match supports unchanged values; mismatch requires row-level baseline/audit review' END) details
FROM baseline b JOIN missing USING(table_name) LEFT JOIN stats s USING(table_name)
ORDER BY b.table_name;

