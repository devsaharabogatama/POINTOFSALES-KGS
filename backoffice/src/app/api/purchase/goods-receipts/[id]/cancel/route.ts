import { apiError,requireActiveCompany,requireCaller } from '@/lib/server-auth'
import { readJsonObject,requiredVersion,uuidValue } from '@/lib/master-data'
import { throwGoodsReceiptError } from '@/lib/goods-receipt'
type Context={params:Promise<{id:string}>}
export async function POST(request:Request,context:Context){try{const caller=await requireCaller(request);await requireActiveCompany(caller);const body=await readJsonObject(request);const {id}=await context.params;const {data,error}=await caller.client.rpc('cancel_backoffice_goods_receipt',{p_document_id:uuidValue(id),p_master_version:requiredVersion(body)});if(error)throwGoodsReceiptError(error);return Response.json({data})}catch(error){return apiError(error)}}
