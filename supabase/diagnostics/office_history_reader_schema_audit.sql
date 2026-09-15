-- Read-only: actual clone/Production reader dependencies, no transaction writes.
SELECT table_name,column_name,data_type FROM information_schema.columns
WHERE table_schema='public' AND table_name IN
 ('sales_headers','sales_details','sales_process_cutover_items','sales_process_cutover_audit','sales_invoice_snapshots')
ORDER BY table_name,ordinal_position;
