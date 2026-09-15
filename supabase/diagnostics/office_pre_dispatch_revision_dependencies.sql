-- SELECT-only actual FK and trigger consumers; no operational writes.
SELECT 'foreign_key' kind,conrelid::regclass::text consumer,conname name,
 pg_get_constraintdef(oid) definition FROM pg_constraint
WHERE contype='f' AND confrelid IN('public.backoffice_sales_order_lines'::regclass,
 'public.backoffice_sales_reservation_lines'::regclass,'public.backoffice_sales_delivery_order_lines'::regclass)
UNION ALL
SELECT 'trigger',tgrelid::regclass::text,tgname,pg_get_triggerdef(oid)
FROM pg_trigger WHERE NOT tgisinternal AND tgrelid IN('public.backoffice_sales_order_lines'::regclass,
 'public.backoffice_sales_reservation_lines'::regclass,'public.backoffice_sales_delivery_order_lines'::regclass,
 'public.backoffice_sales_reservations'::regclass,'public.backoffice_sales_delivery_orders'::regclass)
ORDER BY kind,consumer,name;
