import { ApiRouteError } from '@/lib/server-auth'
import { enumValue, requiredText, requiredVersion, uuidValue } from '@/lib/master-data'

type JsonObject=Record<string,unknown>
type DatabaseError={message?:string}|null

export function parsePurchaseReturnReview(body:JsonObject){const decision=enumValue(body.decision,['APPROVE','REJECT'] as const,'REVIEW_DECISION_INVALID');return {masterVersion:requiredVersion(body),decision,reason:decision==='REJECT'?requiredText(body,'reason',{maxLength:500}):null}}
export function parsePurchaseReturnPost(body:JsonObject){if(typeof body.idempotencyKey!=='string')throw new ApiRouteError('IDEMPOTENCY_KEY_REQUIRED',400);return {masterVersion:requiredVersion(body),idempotencyKey:uuidValue(body.idempotencyKey,'IDEMPOTENCY_KEY_INVALID')}}
export function parsePurchaseReturnCancel(body:JsonObject){return {masterVersion:requiredVersion(body),reason:requiredText(body,'reason',{maxLength:500})}}

export function throwPurchaseReturnRpcError(error:DatabaseError):never{const message=error?.message??'';const known=['PURCHASE_RETURN_NOT_FOUND','PURCHASE_RETURN_NOT_REVIEWABLE','PURCHASE_RETURN_REVIEW_DECISION_INVALID','PURCHASE_RETURN_APPROVER_REQUIRED','REJECTION_REASON_REQUIRED','APPROVED_PURCHASE_RETURN_REQUIRED','PURCHASE_RETURN_ALREADY_POSTED','POSTED_GOODS_RECEIPT_NOT_FOUND','ACTIVE_RETURN_SOURCE_WAREHOUSE_NOT_FOUND','PURCHASE_RETURN_TRANSACTION_CATEGORY_NOT_FOUND','PURCHASE_RETURN_QUANTITY_CHANGED_DURING_POST','PURCHASE_RETURN_FIFO_NOT_AVAILABLE','PURCHASE_RETURN_STOCK_NOT_AVAILABLE','SOURCE_AP_PROVISIONAL_NOT_FOUND','PURCHASE_RETURN_AP_ADJUSTMENT_EXCEEDS_SOURCE','PURCHASE_RETURN_IDEMPOTENCY_CONFLICT','ONLY_DRAFT_PURCHASE_RETURN_CANCELABLE','PURCHASE_RETURN_CANCEL_NOT_ALLOWED','CANCEL_REASON_REQUIRED','MASTER_VERSION_CONFLICT'];const code=known.find((item)=>message.includes(item));if(code)throw new ApiRouteError(code,code.endsWith('_REQUIRED')||code.endsWith('_NOT_ALLOWED')?403:409);throw new ApiRouteError(message||'PURCHASE_RETURN_RPC_FAILED',400)}
