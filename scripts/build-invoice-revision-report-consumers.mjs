import {readFileSync,writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
const source=JSON.parse(readFileSync(process.argv[2],'utf8'));
const out=resolve(process.argv[3]);
const get=key=>{const row=source.routines.find(item=>item.key===key);if(!row)throw Error('RUNTIME_FUNCTION_MISSING:'+key);return row.definition.replaceAll('\r\n','\n')};
const replace=(text,from,to)=>{if(text.split(from).length!==2)throw Error('UNIQUE_RUNTIME_ANCHOR_REQUIRED:'+from.slice(0,80));return text.replace(from,to)};
let ar=get('public.get_finance_ar_aging(p_as_of date, p_customer_id uuid, p_store_id uuid)');
ar=replace(ar,`invoice.invoice_no,invoice.customer_id,customer.code,customer.name,
      invoice.store_id,store.store_name,invoice.invoice_date,schedule.due_date,`,
`invoice.invoice_no,(identity.value->>'customerId')::uuid,customer.code,customer.name,
      invoice.store_id,store.store_name,
      (identity.value->>'invoiceDate')::date,schedule.due_date,`);
ar=replace(ar,`JOIN public.customers customer ON customer.company_id=invoice.company_id
      AND customer.id=invoice.customer_id`,
`JOIN LATERAL(SELECT private.backoffice_invoice_effective_identity(invoice.company_id,invoice.id,v_as_of) value) identity ON true
    JOIN public.customers customer ON customer.company_id=invoice.company_id
      AND customer.id=(identity.value->>'customerId')::uuid`);
ar=replace(ar,`AND invoice.invoice_date<=v_as_of AND schedule.status IN('OPEN','PARTIALLY_PAID','PAID')
      AND (p_customer_id IS NULL OR invoice.customer_id=p_customer_id)`,
`AND (identity.value->>'invoiceDate')::date<=v_as_of AND schedule.status IN('OPEN','PARTIALLY_PAID','PAID')
      AND (p_customer_id IS NULL OR (identity.value->>'customerId')::uuid=p_customer_id)`);

let statement=get('public.get_finance_customer_statement(p_customer_id uuid, p_date_from date, p_as_of date, p_store_id uuid)');
statement=replace(statement,`SELECT invoice.id,'INVOICE','BACKOFFICE',invoice.invoice_no,invoice.invoice_date,`,
`SELECT invoice.id,'INVOICE','BACKOFFICE',invoice.invoice_no,(identity.value->>'invoiceDate')::date,`);
statement=replace(statement,`FROM public.backoffice_sales_invoices invoice
    LEFT JOIN public.stores store ON store.company_id=invoice.company_id AND store.id=invoice.store_id
    WHERE invoice.company_id=v_company AND invoice.customer_id=p_customer_id
      AND invoice.status='POSTED' AND invoice.invoice_date<=v_as_of`,
`FROM public.backoffice_sales_invoices invoice
    JOIN LATERAL(SELECT private.backoffice_invoice_effective_identity(invoice.company_id,invoice.id,v_as_of) value) identity ON true
    LEFT JOIN public.stores store ON store.company_id=invoice.company_id AND store.id=invoice.store_id
    WHERE invoice.company_id=v_company AND (identity.value->>'customerId')::uuid=p_customer_id
      AND invoice.status='POSTED' AND (identity.value->>'invoiceDate')::date<=v_as_of`);
statement=replace(statement,`JOIN public.backoffice_sales_invoices invoice
      ON invoice.company_id=allocation.company_id AND invoice.id=allocation.invoice_id
      AND invoice.customer_id=p_customer_id
    LEFT JOIN public.stores`,
`JOIN public.backoffice_sales_invoices invoice
      ON invoice.company_id=allocation.company_id AND invoice.id=allocation.invoice_id
    JOIN LATERAL(SELECT private.backoffice_invoice_effective_identity(invoice.company_id,invoice.id,v_as_of) value) identity ON true
    LEFT JOIN public.stores`);
statement=replace(statement,`WHERE allocation.company_id=v_company AND receipt.customer_id=p_customer_id
      AND receipt.receipt_date<=v_as_of AND (p_store_id IS NULL OR invoice.store_id=p_store_id)`,
`WHERE allocation.company_id=v_company AND (identity.value->>'customerId')::uuid=p_customer_id
      AND receipt.receipt_date<=v_as_of AND (p_store_id IS NULL OR invoice.store_id=p_store_id)`);
statement=replace(statement,`JOIN public.backoffice_sales_invoices invoice
      ON invoice.company_id=correction.company_id AND invoice.id=correction.source_invoice_id
      AND invoice.customer_id=p_customer_id
    LEFT JOIN public.stores`,
`JOIN public.backoffice_sales_invoices invoice
      ON invoice.company_id=correction.company_id AND invoice.id=correction.source_invoice_id
    JOIN LATERAL(SELECT private.backoffice_invoice_effective_identity(invoice.company_id,invoice.id,v_as_of) value) identity ON true
    LEFT JOIN public.stores`);
statement=replace(statement,`AND (p_store_id IS NULL OR invoice.store_id=p_store_id)
  ),all_rows AS (SELECT * FROM invoice_rows UNION ALL SELECT * FROM receipt_rows),`,
`AND (p_store_id IS NULL OR invoice.store_id=p_store_id)
    UNION ALL
    SELECT revision.id,'INVOICE_REVISION','BACKOFFICE',
      invoice.invoice_no||'-R'||revision.revision_no,revision.revision_date,NULL::date,
      invoice.store_id,store.store_name,greatest(revision.payable_delta,0),
      greatest(-revision.payable_delta,0),'Koreksi Invoice posted'
    FROM private.backoffice_invoice_revisions revision
    JOIN public.backoffice_sales_invoices invoice ON invoice.company_id=revision.company_id
      AND invoice.id=revision.invoice_id
    LEFT JOIN public.stores store ON store.company_id=invoice.company_id AND store.id=invoice.store_id
    WHERE revision.company_id=v_company AND revision.new_customer_id=p_customer_id
      AND revision.revision_date<=v_as_of AND revision.payable_delta<>0
      AND (p_store_id IS NULL OR invoice.store_id=p_store_id)
  ),all_rows AS (SELECT * FROM invoice_rows UNION ALL SELECT * FROM receipt_rows),`);
const terminateDefinition=definition=>definition.trimEnd().endsWith(';')
  ? definition.trimEnd()
  : `${definition.trimEnd()};`;
writeFileSync(out,`-- Generated only from the captured active staging definitions and exact anchors.\n${terminateDefinition(ar)}\n\n${terminateDefinition(statement)}\n`);
console.log(JSON.stringify({status:'GENERATED_EFFECTIVE_REPORT_CONSUMERS',output:out,
 sourceDigests:Object.fromEntries(source.routines.filter(r=>r.key.includes('get_finance_')).map(r=>[r.key,r.digest]))}));
