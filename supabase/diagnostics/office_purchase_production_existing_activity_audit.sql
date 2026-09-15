-- SELECT ONLY. Existing Retail audit trace; no operational RPC or data mutation.
-- Window starts at user-supplied discovery capturedAt, NOT an atomic baseline time.
-- Chronological first278/103 are candidates, NOT stored baseline identity lists.
WITH context AS (
 SELECT '2026-09-15 07:54:29.909584+00'::timestamptz window_start
), old_sales AS (
 SELECT sale.*,row_number() OVER(ORDER BY sale.created_at,sale.id) candidate_no
 FROM public.sales_headers sale
), old_sessions AS (
 SELECT session.*,row_number() OVER(ORDER BY session.opened_at,session.id) candidate_no
 FROM public.cashier_sessions session
), sale_candidates AS (
 SELECT sale.* FROM old_sales sale,context
 WHERE candidate_no<=278 AND (
 sale.updated_at>=window_start OR EXISTS(
 SELECT 1 FROM public.sales_stock_reservation_audit audit
 WHERE audit.company_id=sale.company_id AND audit.sales_id=sale.id
 AND audit.created_at>=window_start))
), sale_trace AS (
 SELECT sale.id,sale.company_id,sale.invoice_no,sale.updated_at,
 jsonb_build_object(
 'salesId',sale.id,'companyId',sale.company_id,'invoiceNo',sale.invoice_no,
 'createdAt',sale.created_at,'updatedAt',sale.updated_at,
 'documentStatus',sale.document_status,'orderRuntimeStatus',sale.order_runtime_status,
 'sjStatus',sale.sj_status,'masterVersion',sale.master_version,
 'grandTotal',sale.grand_total,
 'reservationAudit',COALESCE((
 SELECT jsonb_agg(jsonb_build_object('id',audit.id,'at',audit.created_at,
 'action',audit.action,'actorId',audit.actor_id,'operationId',audit.idempotency_key,
 'before',audit.before_state,
 'afterResult',audit.after_state->'result',
 'afterKeys',ARRAY(SELECT jsonb_object_keys(audit.after_state))) ORDER BY audit.created_at,audit.id)
 FROM public.sales_stock_reservation_audit audit,context
 WHERE audit.company_id=sale.company_id AND audit.sales_id=sale.id
 AND audit.created_at>=window_start),'[]'::jsonb),
 'saleAudit',COALESCE((
 SELECT jsonb_agg(jsonb_build_object('id',audit.id,'at',audit.created_at,
 'action',audit.action,'actorId',audit.actor_id,
 'beforeKeys',ARRAY(SELECT jsonb_object_keys(COALESCE(audit.before_state,'{}'::jsonb))),
 'afterKeys',ARRAY(SELECT jsonb_object_keys(audit.after_state))) ORDER BY audit.created_at,audit.id)
 FROM public.sale_master_audit audit,context
 WHERE audit.company_id=sale.company_id AND audit.sales_id=sale.id
 AND audit.created_at>=window_start),'[]'::jsonb),
 'dispatchEffects',COALESCE((
 SELECT jsonb_agg(jsonb_build_object('id',effect.id,'at',effect.created_at,
 'deliveryId',effect.delivery_document_id,'dispatchedBaseQty',effect.dispatched_base_qty,
 'fifoCostTotal',effect.fifo_cost_total,'eventId',effect.financial_event_id,
 'eventStatus',event.status,'eventError',event.error_message)
 ORDER BY effect.created_at,effect.id)
 FROM public.sales_dispatch_financial_effects effect
 LEFT JOIN public.financial_events event ON event.company_id=effect.company_id
 AND event.id=effect.financial_event_id,context
 WHERE effect.company_id=sale.company_id AND effect.sales_id=sale.id
 AND effect.created_at>=window_start),'[]'::jsonb),
 'currentDetails',COALESCE((
 SELECT jsonb_agg(jsonb_build_object('id',detail.id,'productId',detail.product_id,
 'qty',detail.qty,'price',detail.price,'subtotal',detail.subtotal,
 'cogsUnit',detail.cogs_unit,'cogsTotal',detail.cogs_total,
 'fifoCostTotal',detail.fifo_cost_total) ORDER BY detail.id)
 FROM public.sales_details detail
 WHERE detail.company_id=sale.company_id AND detail.sales_id=sale.id),'[]'::jsonb)
 ) trace FROM sale_candidates sale
), session_trace AS (
 SELECT session.id,jsonb_build_object('sessionId',session.id,'companyId',session.company_id,
 'sessionCode',session.session_code,'openedAt',session.opened_at,'closedAt',session.closed_at,
 'updatedAt',session.updated_at,'status',session.status,
 'audit',COALESCE((
 SELECT jsonb_agg(jsonb_build_object('id',audit.id,'at',audit.created_at,
 'action',audit.action,'actorId',audit.actor_id,
 'before',audit.before_state-'opening_stock_snapshot'-'closing_stock_snapshot',
 'after',audit.after_state-'opening_stock_snapshot'-'closing_stock_snapshot')
 ORDER BY audit.created_at,audit.id)
 FROM public.cashier_session_audit audit,context
 WHERE audit.company_id=session.company_id AND audit.cashier_session_id=session.id
 AND audit.created_at>=window_start),'[]'::jsonb)) trace
 FROM old_sessions session,context WHERE candidate_no<=103
 AND (session.updated_at>=window_start OR session.closed_at>=window_start)
)
SELECT 'old_order_activity'::text check_name,'INFO'::text status,
 jsonb_build_object('windowStart',(SELECT window_start FROM context),
 'candidateOrders',count(*),'documents',COALESCE(jsonb_agg(trace ORDER BY updated_at,id),'[]'::jsonb),
 'limitation','Audit explains recorded operations, not exact full-row baseline equality; no automatic preservation PASS') details
 FROM sale_trace
UNION ALL
SELECT 'old_session_activity','INFO',
 jsonb_build_object('candidateSessions',count(*),'sessions',COALESCE(jsonb_agg(trace ORDER BY id),'[]'::jsonb),
 'limitation','Close audit may explain mutable session values; full baseline row values are unavailable')
 FROM session_trace;
