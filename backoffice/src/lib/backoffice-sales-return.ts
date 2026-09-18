import { ApiRouteError } from "@/lib/server-auth";
import { uuidValue } from "@/lib/master-data";

type JsonObject = Record<string, unknown>;

function requiredUuid(body: JsonObject, field: string) {
  const value = body[field];
  if (typeof value !== "string") throw new ApiRouteError(`${field.toUpperCase()}_REQUIRED`, 400);
  return uuidValue(value, `${field.toUpperCase()}_INVALID`);
}

export function returnOperationId(body: JsonObject) { return requiredUuid(body, "operationId"); }
export function returnExpectedVersion(body: JsonObject) {
  if (!Number.isSafeInteger(body.masterVersion) || Number(body.masterVersion) < 1) {
    throw new ApiRouteError("MASTER_VERSION_REQUIRED", 400);
  }
  return Number(body.masterVersion);
}

export function requiredDate(body: JsonObject, field: string, code: string) {
  const value = body[field];
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new ApiRouteError(code, 400);
  }
  return value;
}

function positiveNumber(value: unknown, code: string) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) throw new ApiRouteError(code, 400);
  return parsed;
}

export function parseReturnDraft(body: JsonObject) {
  if (typeof body.reason !== "string" || !body.reason.trim() || !Array.isArray(body.lines) || !body.lines.length) {
    throw new ApiRouteError("BACKOFFICE_SALES_RETURN_PAYLOAD_INVALID", 400);
  }
  return {
    reason: body.reason.trim().slice(0, 500),
    notes: typeof body.notes === "string" ? body.notes.trim().slice(0, 2000) || null : null,
    lines: body.lines.map((raw) => {
      if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new ApiRouteError("BACKOFFICE_SALES_RETURN_LINE_INVALID", 400);
      const line = raw as JsonObject;
      return {
        salesOrderLineId: requiredUuid(line, "salesOrderLineId"),
        quantityUom: positiveNumber(line.quantityUom, "BACKOFFICE_SALES_RETURN_LINE_INVALID"),
        reason: typeof line.reason === "string" ? line.reason.trim().slice(0, 500) || null : null,
      };
    }),
  };
}

export function parseReturnReceipt(body: JsonObject) {
  if (!Array.isArray(body.lines) || !body.lines.length) throw new ApiRouteError("BACKOFFICE_SALES_RETURN_RECEIPT_INPUT_REQUIRED", 400);
  return body.lines.map((raw) => {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new ApiRouteError("BACKOFFICE_SALES_RETURN_RECEIPT_LINE_INVALID", 400);
    const line = raw as JsonObject;
    const disposition = typeof line.disposition === "string" ? line.disposition.toUpperCase() : "";
    const notes = typeof line.notes === "string" ? line.notes.trim().slice(0, 2000) || null : null;
    if (!['RESTOCK', 'DESTROY'].includes(disposition) || (disposition === 'DESTROY' && !notes)) {
      throw new ApiRouteError("BACKOFFICE_SALES_RETURN_RECEIPT_LINE_INVALID", 400);
    }
    return {
      returnLineId: requiredUuid(line, "returnLineId"),
      quantityUom: positiveNumber(line.quantityUom, "BACKOFFICE_SALES_RETURN_RECEIPT_LINE_INVALID"),
      warehouseId: requiredUuid(line, "warehouseId"), disposition, notes,
    };
  });
}

export function parseReturnAllocations(body: JsonObject) {
  if (!Array.isArray(body.allocations) || !body.allocations.length) throw new ApiRouteError("RETURN_INVOICE_ALLOCATION_REQUIRED", 400);
  return body.allocations.map((raw) => {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new ApiRouteError("RETURN_INVOICE_ALLOCATION_LINE_INVALID", 400);
    const row = raw as JsonObject;
    const allocationType = typeof row.allocationType === "string" ? row.allocationType.toUpperCase() : "";
    if (!['UNINVOICED', 'DRAFT_INVOICE', 'POSTED_INVOICE'].includes(allocationType)) throw new ApiRouteError("RETURN_INVOICE_ALLOCATION_TYPE_INVALID", 400);
    return {
      returnReceiptLineId: requiredUuid(row, "returnReceiptLineId"), allocationType,
      quantityUom: positiveNumber(row.quantityUom, "RETURN_INVOICE_ALLOCATION_LINE_INVALID"),
      invoiceId: allocationType === 'UNINVOICED' ? null : requiredUuid(row, "invoiceId"),
      invoiceLineId: allocationType === 'UNINVOICED' ? null : requiredUuid(row, "invoiceLineId"),
    };
  });
}

export function throwBackofficeReturnError(error: { code?: string; message?: string } | null): never {
  const message = error?.message ?? "";
  const codes = [
    "CUSTOM_PERMISSION_DENIED", "BACKOFFICE_SALES_RETURN_NOT_FOUND", "BACKOFFICE_SALES_RETURN_SOURCE_NOT_FOUND",
    "BACKOFFICE_SALES_RETURN_PAYLOAD_INVALID", "BACKOFFICE_SALES_RETURN_LINE_INVALID", "BACKOFFICE_SALES_RETURN_QUANTITY_EXCEEDS_RETURNABLE",
    "BACKOFFICE_SALES_RETURN_NOT_DRAFT", "BACKOFFICE_SALES_RETURN_SUBMIT_STATE_INVALID", "BACKOFFICE_SALES_RETURN_APPROVE_STATE_INVALID",
    "BACKOFFICE_SALES_RETURN_CANCEL_STATE_INVALID", "BACKOFFICE_SALES_RETURN_RECEIPT_INPUT_REQUIRED", "BACKOFFICE_SALES_RETURN_RECEIPT_LINE_INVALID",
    "BACKOFFICE_SALES_RETURN_RECEIPT_STATE_INVALID", "BACKOFFICE_SALES_RETURN_ALREADY_FULLY_RECEIVED", "BACKOFFICE_SALES_RETURN_RECEIPT_QUANTITY_EXCEEDS_APPROVED",
    "BACKOFFICE_SALES_RETURN_RECEIPT_WAREHOUSE_INVALID", "BACKOFFICE_SALES_RETURN_SOURCE_FIFO_EXHAUSTED", "RETURN_INVOICE_ALLOCATION_REQUIRED",
    "RETURN_INVOICE_ALLOCATION_LINE_INVALID", "RETURN_INVOICE_ALLOCATION_TYPE_INVALID", "RETURN_RECEIPT_QUANTITY_ALREADY_ALLOCATED",
    "UNINVOICED_RETURN_QUANTITY_NOT_AVAILABLE", "RETURN_SOURCE_INVOICE_LINE_INVALID", "DRAFT_INVOICE_REQUIRED", "POSTED_INVOICE_REQUIRED",
    "DRAFT_INVOICE_RETURN_QUANTITY_EXCEEDS_LINE", "CREDIT_NOTE_NOT_FOUND", "CREDIT_NOTE_NOT_EDITABLE", "CREDIT_NOTE_NOT_POSTABLE",
    "CREDIT_NOTE_DATE_FUTURE", "CREDIT_NOTE_DATE_BEFORE_PAYMENT", "CREDIT_NOTE_DELIVERY_FEE_EXCEEDS_SOURCE", "POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND",
    "CUSTOMER_REFUND_CREDIT_NOTE_NOT_FOUND", "CUSTOMER_REFUND_CREDIT_NOTE_NOT_ELIGIBLE", "CUSTOMER_REFUND_DATE_INVALID",
    "CUSTOMER_REFUND_PAYMENT_METHOD_INVALID", "CUSTOMER_REFUND_EVIDENCE_REQUIRED", "CUSTOMER_REFUND_AMOUNT_EXCEEDS_LIABILITY",
    "CUSTOMER_REFUND_NOT_FOUND", "CUSTOMER_REFUND_NOT_REVERSIBLE", "CUSTOMER_REFUND_ALREADY_REVERSED", "CUSTOMER_REFUND_REVERSAL_DATE_INVALID",
    "MASTER_VERSION_CONFLICT", "IDEMPOTENCY_PAYLOAD_CONFLICT", "IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_REQUEST", "CANCEL_REASON_REQUIRED",
  ];
  const known = codes.find((code) => message.includes(code));
  if (known) {
    const status = known.includes("NOT_FOUND") ? 404 : known === "CUSTOM_PERMISSION_DENIED" ? 403
      : known.includes("VERSION_CONFLICT") || known.includes("IDEMPOTENCY") ? 409 : 400;
    throw new ApiRouteError(known, status);
  }
  if (error?.code === "42501") throw new ApiRouteError("FORBIDDEN", 403);
  throw new ApiRouteError(message || "BACKOFFICE_SALES_RETURN_OPERATION_FAILED", 500);
}
