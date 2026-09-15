-- Read-only evidence for the historical-clone unit 46 fixture audit.
-- This does not activate Office, switch Company mode, or execute Dispatch.
SELECT setting.active_mode,count(*) AS company_rows
FROM public.company_sales_process_settings setting
JOIN public.companies company ON company.id=setting.company_id
WHERE company.status='ACTIVE'
GROUP BY setting.active_mode
ORDER BY setting.active_mode;
