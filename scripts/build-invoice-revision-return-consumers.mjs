import {readFileSync,writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
const source=JSON.parse(readFileSync(process.argv[2],'utf8')),out=resolve(process.argv[3]);
const get=prefix=>{const row=source.routines.find(item=>item.key.startsWith(prefix));if(!row?.definition)throw Error('RETURN_RUNTIME_MISSING:'+prefix);return row.definition.replaceAll('\r\n','\n')};
const replace=(text,from,to)=>{if(text.split(from).length!==2)throw Error('UNIQUE_RETURN_ANCHOR_REQUIRED:'+from.slice(0,90));return text.replace(from,to)};
let allocate=get('private.allocate_backoffice_sales_return_invoices_before_retained(');
allocate=replace(allocate,`  v_effective_line jsonb;`,`  v_effective_line jsonb;v_effective_identity jsonb;`);
allocate=replace(allocate,`    IF v_invoice.status<>'POSTED' THEN
      RAISE EXCEPTION 'POSTED_INVOICE_REQUIRED: tujuan yang dipilih belum menjadi Posted Invoice';
    END IF;`,`    IF v_invoice.status<>'POSTED' THEN
      RAISE EXCEPTION 'POSTED_INVOICE_REQUIRED: tujuan yang dipilih belum menjadi Posted Invoice';
    END IF;
    v_effective_identity:=private.backoffice_invoice_effective_identity(v_company,v_invoice.id,NULL);`);
allocate=replace(allocate,`VALUES(v_note_id,v_company,p_return_id,v_invoice.id,v_invoice.customer_id,`,`VALUES(v_note_id,v_company,p_return_id,v_invoice.id,(v_effective_identity->>'customerId')::uuid,`);
allocate=replace(allocate,`private.backoffice_sales_invoice_snapshot(v_company,v_invoice.id),v_actor,v_actor,`,`private.backoffice_sales_invoice_snapshot(v_company,v_invoice.id)||jsonb_build_object(
          'effectiveIdentity',v_effective_identity),v_actor,v_actor,`);

let post=get('private.post_backoffice_sales_credit_note_before_retained(');
post=replace(post,`  v_company_today date;v_latest_payment_date date;`,`  v_company_today date;v_latest_payment_date date;v_effective_identity jsonb;
  v_effective_total numeric(24,4);`);
post=replace(post,`  SELECT * INTO STRICT v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.id=v_note.source_invoice_id
    AND invoice.status='POSTED' FOR UPDATE;`,`  SELECT * INTO STRICT v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.id=v_note.source_invoice_id
    AND invoice.status='POSTED' FOR UPDATE;
  v_effective_identity:=private.backoffice_invoice_effective_identity(v_company,v_invoice.id,NULL);
  v_effective_total:=private.backoffice_invoice_effective_total(v_company,v_invoice.id,NULL);
  IF v_note.customer_id<>(v_effective_identity->>'customerId')::uuid THEN
    RAISE EXCEPTION 'CREDIT_NOTE_INVOICE_IDENTITY_CHANGED: batalkan Draft Credit Note lalu alokasikan ulang Retur';
  END IF;`);
post=replace(post,`IF v_prior_credit+v_note.grand_total>v_invoice.grand_total THEN`,`IF v_prior_credit+v_note.grand_total>v_effective_total THEN`);
post=replace(post,`v_outstanding:=greatest(0,round(v_invoice.grand_total-v_paid-v_prior_credit,4));`,`v_outstanding:=greatest(0,round(v_effective_total-v_paid-v_prior_credit,4));`);
const end=definition=>definition.trimEnd().endsWith(';')?definition.trimEnd():definition.trimEnd()+';';
writeFileSync(out,`-- Generated only from captured active staging Return/Credit Note core definitions.\n${end(allocate)}\n\n${end(post)}\n`);
console.log(JSON.stringify({status:'GENERATED_EFFECTIVE_RETURN_CONSUMERS',output:out}));
