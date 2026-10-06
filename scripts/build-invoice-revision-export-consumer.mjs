import {readFileSync,writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
const source=JSON.parse(readFileSync(process.argv[2],'utf8'));
const out=resolve(process.argv[3]);
const row=source.routines.find(item=>item.key.startsWith('public.export_sales_documents('));
if(!row?.definition)throw Error('EXPORT_RUNTIME_FUNCTION_MISSING');
const replace=(text,from,to)=>{if(text.split(from).length!==2)throw Error('UNIQUE_EXPORT_ANCHOR_REQUIRED:'+from.slice(0,80));return text.replace(from,to)};
let definition=row.definition.replaceAll('\r\n','\n');
definition=replace(definition,`SELECT invoice.*,document.order_no,document.fulfillment_status,document.is_tempo,
        store.store_name,customer.code customer_code,customer.name customer_name,`,
`SELECT invoice.*,document.order_no,document.fulfillment_status,document.is_tempo,
        (identity.value->>'invoiceDate')::date effective_invoice_date,
        store.store_name,customer.code customer_code,customer.name customer_name,`);
definition=replace(definition,`FROM public.backoffice_sales_invoices invoice
      JOIN public.backoffice_sales_orders document`,
`FROM public.backoffice_sales_invoices invoice
      JOIN LATERAL(SELECT private.backoffice_invoice_effective_identity(invoice.company_id,invoice.id,NULL) value) identity ON true
      JOIN public.backoffice_sales_orders document`);
definition=replace(definition,`LEFT JOIN public.customers customer ON customer.company_id=invoice.company_id
        AND customer.id=invoice.customer_id`,
`LEFT JOIN public.customers customer ON customer.company_id=invoice.company_id
        AND customer.id=(identity.value->>'customerId')::uuid`);
definition=replace(definition,`AND invoice.invoice_date BETWEEN p_date_from AND p_date_to`,
`AND (identity.value->>'invoiceDate')::date BETWEEN p_date_from AND p_date_to`);
definition=replace(definition,`scoped.invoice_no,scoped.draft_no,scoped.order_no,scoped.invoice_date,
        scoped.status`,
`scoped.invoice_no,scoped.draft_no,scoped.order_no,scoped.effective_invoice_date,
        scoped.status`);
definition=replace(definition,`scoped.is_tempo,scoped.due_date,scoped.charge_total,scoped.discount_total,
        0::numeric,scoped.discount_total,scoped.tax_total,scoped.delivery_fee_amount,
        0::numeric,scoped.grand_total,scoped.paid_amount,
        greatest(scoped.grand_total-scoped.paid_amount,0),`,
`scoped.is_tempo,scoped.due_date,
        scoped.charge_total-COALESCE((SELECT sum(line.line_amount+line.discount_amount) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id AND line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER'),0)+COALESCE((SELECT sum(CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (private.backoffice_invoice_effective_line_amounts(scoped.company_id,line.id)->>'chargeAmount')::numeric ELSE 0 END) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id),0),
        scoped.discount_total-COALESCE((SELECT sum(line.discount_amount) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id AND line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER'),0)+COALESCE((SELECT sum(CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (private.backoffice_invoice_effective_line_amounts(scoped.company_id,line.id)->>'discountAmount')::numeric ELSE 0 END) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id),0),
        0::numeric,
        scoped.discount_total-COALESCE((SELECT sum(line.discount_amount) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id AND line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER'),0)+COALESCE((SELECT sum(CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (private.backoffice_invoice_effective_line_amounts(scoped.company_id,line.id)->>'discountAmount')::numeric ELSE 0 END) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id),0),
        scoped.tax_total-COALESCE((SELECT sum(line.tax_amount) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id AND line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER'),0)+COALESCE((SELECT sum(CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (private.backoffice_invoice_effective_line_amounts(scoped.company_id,line.id)->>'taxAmount')::numeric ELSE 0 END) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id),0),
        scoped.delivery_fee_amount,0::numeric,
        private.backoffice_invoice_effective_total(scoped.company_id,scoped.id,NULL),scoped.paid_amount,
        greatest(private.backoffice_invoice_effective_total(scoped.company_id,scoped.id,NULL)-scoped.paid_amount,0),`);
definition=replace(definition,`invoice.invoice_no,invoice.draft_no,invoice.order_no,invoice.invoice_date,
        invoice.status`,
`invoice.invoice_no,invoice.draft_no,invoice.order_no,invoice.effective_invoice_date,
        invoice.status`);
definition=replace(definition,`COALESCE(line.quantity_base,0),line.unit_price,line.discount_amount,
        COALESCE(line.source_snapshot->>'taxCode',''),`,
`COALESCE(line.quantity_base,0),
        CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (effective.value->>'enteredUnitPrice')::numeric ELSE line.unit_price END,
        CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (effective.value->>'discountAmount')::numeric ELSE line.discount_amount END,
        COALESCE(line.source_snapshot->>'taxCode',''),`);
definition=replace(definition,`COALESCE(NULLIF(line.source_snapshot->>'taxRatePercent','')::numeric,0),
        line.tax_amount,line.line_amount
      FROM backoffice_scoped invoice
      JOIN public.backoffice_sales_invoice_lines line`,
`COALESCE(NULLIF(line.source_snapshot->>'taxRatePercent','')::numeric,0),
        CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (effective.value->>'taxAmount')::numeric ELSE line.tax_amount END,
        CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (effective.value->>'lineAmount')::numeric ELSE line.line_amount END
      FROM backoffice_scoped invoice
      JOIN public.backoffice_sales_invoice_lines line`);
definition=replace(definition,`AND line.invoice_id=invoice.id
      LEFT JOIN public.backoffice_sales_order_lines source`,
`AND line.invoice_id=invoice.id
      LEFT JOIN LATERAL(SELECT CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER'
        THEN private.backoffice_invoice_effective_line_amounts(line.company_id,line.id) END value) effective ON true
      LEFT JOIN public.backoffice_sales_order_lines source`);
writeFileSync(out,`-- Generated only from the captured active staging export definition and exact anchors.\n${definition.trimEnd()};\n`);
console.log(JSON.stringify({status:'GENERATED_EFFECTIVE_EXPORT_CONSUMER',sourceDigest:row.digest,output:out}));
