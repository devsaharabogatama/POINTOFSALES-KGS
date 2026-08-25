import { apiError,requireActiveCompany,requireCaller } from '@/lib/server-auth'
import { readJsonObject } from '@/lib/master-data'
import { parseGoodsReceipt,throwGoodsReceiptError } from '@/lib/goods-receipt'

export async function GET(request:Request){try{const caller=await requireCaller(request);await requireActiveCompany(caller);const {data,error}=await caller.client.rpc('get_backoffice_goods_receipt_workspace');if(error)throwGoodsReceiptError(error);return Response.json(data??{})}catch(error){return apiError(error)}}
export async function POST(request:Request){try{const caller=await requireCaller(request);await requireActiveCompany(caller);const input=parseGoodsReceipt(await readJsonObject(request));const {data,error}=await caller.client.rpc('save_backoffice_goods_receipt',{p_document_id:input.documentId,p_master_version:input.masterVersion,p_supplier_order_id:input.supplierOrderId,p_supplier_delivery_no:input.supplierDeliveryNo,p_notes:input.notes,p_lines:input.lines});if(error)throwGoodsReceiptError(error);return Response.json({data},{status:input.documentId?200:201})}catch(error){return apiError(error)}}
