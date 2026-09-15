-- Read-only exact row-value fingerprints; no transaction contents or secrets are returned.
SELECT 'sales_headers'::text table_name,count(*)::bigint rows,
 md5(COALESCE(string_agg(to_jsonb(source)::text,E'\n' ORDER BY to_jsonb(source)::text),'')) row_value_digest
 FROM public.sales_headers source
UNION ALL
SELECT 'sales_details'::text table_name,count(*)::bigint rows,
 md5(COALESCE(string_agg(to_jsonb(source)::text,E'\n' ORDER BY to_jsonb(source)::text),'')) row_value_digest
 FROM public.sales_details source
UNION ALL
SELECT 'supplier_order_documents'::text table_name,count(*)::bigint rows,
 md5(COALESCE(string_agg(to_jsonb(source)::text,E'\n' ORDER BY to_jsonb(source)::text),'')) row_value_digest
 FROM public.supplier_order_documents source
UNION ALL
SELECT 'supplier_order_lines'::text table_name,count(*)::bigint rows,
 md5(COALESCE(string_agg(to_jsonb(source)::text,E'\n' ORDER BY to_jsonb(source)::text),'')) row_value_digest
 FROM public.supplier_order_lines source
UNION ALL
SELECT 'goods_receipt_documents'::text table_name,count(*)::bigint rows,
 md5(COALESCE(string_agg(to_jsonb(source)::text,E'\n' ORDER BY to_jsonb(source)::text),'')) row_value_digest
 FROM public.goods_receipt_documents source
UNION ALL
SELECT 'goods_receipt_lines'::text table_name,count(*)::bigint rows,
 md5(COALESCE(string_agg(to_jsonb(source)::text,E'\n' ORDER BY to_jsonb(source)::text),'')) row_value_digest
 FROM public.goods_receipt_lines source
UNION ALL
SELECT 'purchase_return_documents'::text table_name,count(*)::bigint rows,
 md5(COALESCE(string_agg(to_jsonb(source)::text,E'\n' ORDER BY to_jsonb(source)::text),'')) row_value_digest
 FROM public.purchase_return_documents source
UNION ALL
SELECT 'supplier_invoice_documents'::text table_name,count(*)::bigint rows,
 md5(COALESCE(string_agg(to_jsonb(source)::text,E'\n' ORDER BY to_jsonb(source)::text),'')) row_value_digest
 FROM public.supplier_invoice_documents source
UNION ALL
SELECT 'supplier_payment_documents'::text table_name,count(*)::bigint rows,
 md5(COALESCE(string_agg(to_jsonb(source)::text,E'\n' ORDER BY to_jsonb(source)::text),'')) row_value_digest
 FROM public.supplier_payment_documents source
UNION ALL
SELECT 'stock_movements'::text table_name,count(*)::bigint rows,
 md5(COALESCE(string_agg(to_jsonb(source)::text,E'\n' ORDER BY to_jsonb(source)::text),'')) row_value_digest
 FROM public.stock_movements source
UNION ALL
SELECT 'product_stocks'::text table_name,count(*)::bigint rows,
 md5(COALESCE(string_agg(to_jsonb(source)::text,E'\n' ORDER BY to_jsonb(source)::text),'')) row_value_digest
 FROM public.product_stocks source
UNION ALL
SELECT 'product_batches'::text table_name,count(*)::bigint rows,
 md5(COALESCE(string_agg(to_jsonb(source)::text,E'\n' ORDER BY to_jsonb(source)::text),'')) row_value_digest
 FROM public.product_batches source
UNION ALL
SELECT 'financial_events'::text table_name,count(*)::bigint rows,
 md5(COALESCE(string_agg(to_jsonb(source)::text,E'\n' ORDER BY to_jsonb(source)::text),'')) row_value_digest
 FROM public.financial_events source
UNION ALL
SELECT 'finance_journals'::text table_name,count(*)::bigint rows,
 md5(COALESCE(string_agg(to_jsonb(source)::text,E'\n' ORDER BY to_jsonb(source)::text),'')) row_value_digest
 FROM public.finance_journals source
UNION ALL
SELECT 'finance_journal_lines'::text table_name,count(*)::bigint rows,
 md5(COALESCE(string_agg(to_jsonb(source)::text,E'\n' ORDER BY to_jsonb(source)::text),'')) row_value_digest
 FROM public.finance_journal_lines source
UNION ALL
SELECT 'cashier_sessions'::text table_name,count(*)::bigint rows,
 md5(COALESCE(string_agg(to_jsonb(source)::text,E'\n' ORDER BY to_jsonb(source)::text),'')) row_value_digest
 FROM public.cashier_sessions source
UNION ALL
SELECT 'customer_receipt_documents'::text table_name,count(*)::bigint rows,
 md5(COALESCE(string_agg(to_jsonb(source)::text,E'\n' ORDER BY to_jsonb(source)::text),'')) row_value_digest
 FROM public.customer_receipt_documents source
ORDER BY table_name;
