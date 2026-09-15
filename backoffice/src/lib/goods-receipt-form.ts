export type Order = { id:string;order_no:string;supplier_name:string;status:string;expected_date:string|null };
export type OrderLine = { id:string;document_id:string;product_id:string;ordered_uom_id:string;ordered_qty:number|string;product_name_snapshot:string;ordered_uom_name_snapshot:string;destination_warehouse_id:string|null;remaining_base_qty:number|string };
export type Uom = { product_id:string;uom_id:string;factor_to_base:number|string;uom_name:string;allow_decimal:boolean;decimal_precision:number|string };
export type Draft = { id:string;receipt_no:string;supplier_order_id:string;supplier_delivery_no:string|null;notes:string|null;master_version:number|string;received_by:string;warehouse_id:string;warehouse_name:string;line_count:number|string };
export type DraftLine = { document_id:string;client_line_key:string;supplier_order_line_id:string;received_uom_id:string;received_qty:number|string;accepted_good_qty:number|string;damaged_qty:number|string;rejected_qty:number|string };
export type Workspace = { orders?:Order[];orderLines?:OrderLine[];productUoms?:Uom[];drafts?:Draft[];draftLines?:DraftLine[];error?:string };
export type FormLine = { key:string;sourceId:string;uomId:string;received:string;good:string;damaged:string;rejected:string;detailed:boolean };
export type ReceiptForm = { order:Order;draft:Draft;lines:FormLine[];deliveryNo:string;notes:string;idempotencyKey:string;error:string;posting:boolean };
function defaultReceiptValue(line:OrderLine,productUoms:Uom[]){
  const remaining=Number(line.remaining_base_qty);
  const candidates=productUoms.filter((candidate)=>candidate.product_id===line.product_id&&Number(candidate.factor_to_base)>0);
  const ordered=candidates.find((candidate)=>candidate.uom_id===line.ordered_uom_id);
  const representsExactly=(uom:Uom)=>{const factor=Number(uom.factor_to_base),raw=remaining/factor,precision=uom.allow_decimal?Math.max(0,Number(uom.decimal_precision||6)):0;return Math.abs(Number(raw.toFixed(precision))*factor-remaining)<0.000001};
  const uom=(ordered&&representsExactly(ordered)?ordered:undefined)??candidates.find((candidate)=>Number(candidate.factor_to_base)===1&&representsExactly(candidate))??candidates.find(representsExactly)??ordered;
  if(!uom)return {uomId:line.ordered_uom_id,quantity:""};
  const precision=uom.allow_decimal?Math.max(0,Number(uom.decimal_precision||6)):0;
  return {uomId:uom.uom_id,quantity:String(Number((remaining/Number(uom.factor_to_base)).toFixed(precision)))};
}

export function buildForm(workspace:Workspace,order:Order,draft:Draft):ReceiptForm{
  const saved=new Map((workspace.draftLines??[]).filter((item)=>item.document_id===draft.id).map((item)=>[item.supplier_order_line_id,item]));
  const lines=(workspace.orderLines??[]).filter((line)=>line.document_id===order.id&&(saved.has(line.id)||(line.destination_warehouse_id===draft.warehouse_id&&Number(line.remaining_base_qty)>0))).map((line)=>{
    const old=saved.get(line.id);
    const fallback=defaultReceiptValue(line,workspace.productUoms??[]);
    const received=old?String(old.received_qty):fallback.quantity;
    return {key:old?.client_line_key??crypto.randomUUID(),sourceId:line.id,uomId:old?.received_uom_id??fallback.uomId,received,good:old?String(old.accepted_good_qty):received,damaged:old?String(old.damaged_qty):"0",rejected:old?String(old.rejected_qty):"0",detailed:Boolean(old&&(Number(old.damaged_qty)>0||Number(old.rejected_qty)>0))};
  });
  return {order,draft,lines,deliveryNo:draft.supplier_delivery_no??"",notes:draft.notes??"",idempotencyKey:crypto.randomUUID(),error:"",posting:false};
}
