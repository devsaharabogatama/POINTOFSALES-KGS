import { ApiRouteError } from '@/lib/server-auth'
import { optionalText, requiredVersion, uuidValue } from '@/lib/master-data'

type JsonObject=Record<string,unknown>
function uuid(body:JsonObject,key:string){const value=body[key];if(typeof value!=='string')throw new ApiRouteError(`${key.toUpperCase()}_REQUIRED`,400);return uuidValue(value,`${key.toUpperCase()}_INVALID`)}
function quantity(value:unknown){const number=Number(value);if(!Number.isFinite(number)||number<0)throw new ApiRouteError('GOODS_RECEIPT_QUANTITY_INVALID',400);return number}

export function parseGoodsReceipt(body:JsonObject){
  if(!Array.isArray(body.lines)||body.lines.length===0)throw new ApiRouteError('GOODS_RECEIPT_LINES_REQUIRED',400)
  return {
    documentId:body.documentId===null||body.documentId===undefined?null:uuid(body,'documentId'),
    masterVersion:body.documentId===null||body.documentId===undefined?null:requiredVersion(body),
    supplierOrderId:uuid(body,'supplierOrderId'),
    supplierDeliveryNo:optionalText(body,'supplierDeliveryNo',{maxLength:200})??null,
    notes:optionalText(body,'notes',{maxLength:1000})??null,
    lines:body.lines.map((raw,index)=>{
      if(!raw||typeof raw!=='object'||Array.isArray(raw))throw new ApiRouteError(`GOODS_RECEIPT_LINE_${index+1}_INVALID`,400)
      const line=raw as JsonObject
      return {clientLineKey:uuid(line,'clientLineKey'),supplierOrderLineId:uuid(line,'supplierOrderLineId'),receivedUomId:uuid(line,'receivedUomId'),receivedQty:quantity(line.receivedQty),acceptedGoodQty:quantity(line.acceptedGoodQty),damagedQty:quantity(line.damagedQty),rejectedQty:quantity(line.rejectedQty)}
    }),
  }
}

export function throwGoodsReceiptError(error:{code?:string;message?:string}|null):never{
  const message=error?.message??''
  const code=['CUSTOM_PERMISSION_DENIED','RECEIVABLE_SUPPLIER_ORDER_NOT_FOUND','GOODS_RECEIPT_LINES_REQUIRED','GOODS_RECEIPT_CONDITION_TOTAL_INVALID','ACTIVE_DAMAGED_WAREHOUSE_NOT_FOUND','ACTIVE_PURCHASE_PRODUCT_UOM_NOT_FOUND','PURCHASE_UOM_REQUIRES_INTEGER','MASTER_VERSION_CONFLICT','FINAL_GOODS_RECEIPT_IMMUTABLE','GOODS_RECEIPT_OWNER_SCOPE_INVALID','GOODS_RECEIPT_IDEMPOTENCY_CONFLICT'].find((item)=>message.includes(item))
  if(code)throw new ApiRouteError(code,code==='CUSTOM_PERMISSION_DENIED'?403:code==='MASTER_VERSION_CONFLICT'?409:400)
  if(error?.code==='42501')throw new ApiRouteError('FORBIDDEN',403)
  throw new ApiRouteError(message||'GOODS_RECEIPT_OPERATION_FAILED',500)
}
