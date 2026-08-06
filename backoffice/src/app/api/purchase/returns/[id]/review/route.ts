import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import { parsePurchaseReturnReview, throwPurchaseReturnRpcError } from '@/lib/purchase-return'
type RouteContext={params:Promise<{id:string}>}
export async function POST(request:Request,context:RouteContext){try{const caller=await requireCaller(request);await requireActiveCompany(caller);const {id}=await context.params;const input=parsePurchaseReturnReview(await readJsonObject(request));const {data,error}=await caller.client.rpc('review_purchase_return',{p_document_id:uuidValue(id),p_master_version:input.masterVersion,p_decision:input.decision,p_reason:input.reason});if(error)throwPurchaseReturnRpcError(error);return Response.json({data})}catch(error){return apiError(error)}}
