import { ApiRouteError } from "@/lib/server-auth";
import {
  enumValue,
  optionalText,
  requiredText,
  requiredVersion,
  uuidValue,
} from "@/lib/master-data";

type JsonObject = Record<string, unknown>;
type DatabaseError = { message?: string } | null;

function uuid(body: JsonObject, key: string) {
  const value = body[key];
  if (typeof value !== "string")
    throw new ApiRouteError(`${key.toUpperCase()}_REQUIRED`, 400);
  return uuidValue(value, `${key.toUpperCase()}_INVALID`);
}

export function parseBackofficePurchaseReturnDraft(body: JsonObject) {
  if (!Array.isArray(body.lines) || body.lines.length === 0)
    throw new ApiRouteError("PURCHASE_RETURN_LINES_REQUIRED", 400);
  const documentId =
    body.documentId === null || body.documentId === undefined
      ? null
      : uuid(body, "documentId");
  const returnDate = requiredText(body, "returnDate", { maxLength: 10 });
  if (!/^\d{4}-\d{2}-\d{2}$/.test(returnDate))
    throw new ApiRouteError("RETURN_DATE_INVALID", 400);
  return {
    documentId,
    masterVersion: documentId ? requiredVersion(body) : null,
    operationId: uuid(body, "operationId"),
    sourceReceiptId: uuid(body, "sourceReceiptId"),
    sourceWarehouseId: uuid(body, "sourceWarehouseId"),
    returnDate,
    returnReason: requiredText(body, "returnReason", { maxLength: 500 }),
    supplierDocumentNo:
      optionalText(body, "supplierDocumentNo", { maxLength: 200 }) ?? null,
    notes: optionalText(body, "notes", { maxLength: 1000 }) ?? null,
    lines: body.lines.map((raw, index) => {
      if (!raw || typeof raw !== "object" || Array.isArray(raw))
        throw new ApiRouteError(
          `PURCHASE_RETURN_LINE_${index + 1}_INVALID`,
          400,
        );
      const line = raw as JsonObject;
      const returnQty = Number(line.returnQty);
      if (!Number.isFinite(returnQty) || returnQty <= 0)
        throw new ApiRouteError("PURCHASE_RETURN_QUANTITY_INVALID", 400);
      return {
        clientLineKey: uuid(line, "clientLineKey"),
        sourceConditionAllocationId: uuid(
          line,
          "sourceConditionAllocationId",
        ),
        returnUomId: uuid(line, "returnUomId"),
        returnQty,
      };
    }),
  };
}

export function parsePurchaseReturnReview(body: JsonObject) {
  const decision = enumValue(
    body.decision,
    ["APPROVE", "REJECT"] as const,
    "REVIEW_DECISION_INVALID",
  );
  return {
    masterVersion: requiredVersion(body),
    decision,
    reason:
      decision === "REJECT"
        ? requiredText(body, "reason", { maxLength: 500 })
        : null,
  };
}
export function parsePurchaseReturnPost(body: JsonObject) {
  if (typeof body.idempotencyKey !== "string")
    throw new ApiRouteError("IDEMPOTENCY_KEY_REQUIRED", 400);
  return {
    masterVersion: requiredVersion(body),
    idempotencyKey: uuidValue(body.idempotencyKey, "IDEMPOTENCY_KEY_INVALID"),
  };
}
export function parsePurchaseReturnCancel(body: JsonObject) {
  return {
    masterVersion: requiredVersion(body),
    reason: requiredText(body, "reason", { maxLength: 500 }),
  };
}

export function throwPurchaseReturnRpcError(error: DatabaseError): never {
  const message = error?.message ?? "";
  const known = [
    "CUSTOM_PERMISSION_DENIED",
    "PURCHASE_RETURN_NOT_FOUND",
    "PURCHASE_RETURN_NOT_REVIEWABLE",
    "PURCHASE_RETURN_REVIEW_DECISION_INVALID",
    "PURCHASE_RETURN_APPROVER_REQUIRED",
    "REJECTION_REASON_REQUIRED",
    "APPROVED_PURCHASE_RETURN_REQUIRED",
    "PURCHASE_RETURN_ALREADY_POSTED",
    "POSTED_GOODS_RECEIPT_NOT_FOUND",
    "ACTIVE_RETURN_SOURCE_WAREHOUSE_NOT_FOUND",
    "PURCHASE_RETURN_TRANSACTION_CATEGORY_NOT_FOUND",
    "PURCHASE_RETURN_QUANTITY_CHANGED_DURING_POST",
    "PURCHASE_RETURN_FIFO_NOT_AVAILABLE",
    "PURCHASE_RETURN_STOCK_NOT_AVAILABLE",
    "SOURCE_AP_PROVISIONAL_NOT_FOUND",
    "PURCHASE_RETURN_AP_ADJUSTMENT_EXCEEDS_SOURCE",
    "PURCHASE_RETURN_PROVISIONAL_VALUE_RECONCILIATION_FAILED",
    "PURCHASE_RETURN_INVOICE_ALLOCATION_GAP",
    "PURCHASE_RETURN_JOURNAL_UNBALANCED",
    "PURCHASE_RETURN_JOURNAL_RECONCILIATION_FAILED",
    "POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND",
    "SUPPLIER_ASSIGNMENT_REQUIRED",
    "PURCHASE_RETURN_STORE_SCOPE_INVALID",
    "ACTIVE_PURCHASE_RETURN_DRAFT_ALREADY_EXISTS",
    "PURCHASE_RETURN_DRAFT_IDEMPOTENCY_CONFLICT",
    "PURCHASE_RETURN_CHANNEL_INVALID",
    "PURCHASE_RETURN_QUANTITY_EXCEEDS_AVAILABLE",
    "RETURNABLE_RECEIPT_ALLOCATION_NOT_FOUND",
    "ACTIVE_RETURN_PRODUCT_UOM_NOT_FOUND",
    "RETURN_UOM_REQUIRES_INTEGER",
    "PURCHASE_RETURN_QUANTITY_INVALID",
    "PURCHASE_RETURN_IDEMPOTENCY_CONFLICT",
    "ONLY_DRAFT_PURCHASE_RETURN_CANCELABLE",
    "PURCHASE_RETURN_CANCEL_NOT_ALLOWED",
    "CANCEL_REASON_REQUIRED",
    "MASTER_VERSION_CONFLICT",
  ];
  const code = known.find((item) => message.includes(item));
  if (code)
    throw new ApiRouteError(
      code,
      code === "CUSTOM_PERMISSION_DENIED" ||
        code.endsWith("_REQUIRED") ||
        code.endsWith("_NOT_ALLOWED")
        ? 403
        : 409,
    );
  throw new ApiRouteError(message || "PURCHASE_RETURN_RPC_FAILED", 400);
}
