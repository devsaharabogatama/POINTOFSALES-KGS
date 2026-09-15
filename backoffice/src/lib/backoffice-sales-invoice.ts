import { ApiRouteError } from "@/lib/server-auth";
import { uuidValue } from "@/lib/master-data";

type JsonObject = Record<string, unknown>;

function requiredUuid(body: JsonObject, field: string) {
  const value = body[field];
  if (typeof value !== "string") throw new ApiRouteError(`${field.toUpperCase()}_REQUIRED`, 400);
  return uuidValue(value, `${field.toUpperCase()}_INVALID`);
}

function dateValue(value: unknown, code: string) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new ApiRouteError(code, 400);
  }
  return value;
}

export function invoiceOperationId(body: JsonObject) { return requiredUuid(body, "operationId"); }

export function invoiceExpectedVersion(body: JsonObject) {
  if (!Number.isSafeInteger(body.masterVersion) || Number(body.masterVersion) < 1) {
    throw new ApiRouteError("MASTER_VERSION_REQUIRED", 400);
  }
  return Number(body.masterVersion);
}

export function parseBackofficeInvoicePayload(body: JsonObject) {
  if ((body.lines !== undefined && !Array.isArray(body.lines)) ||
    (body.acceptedOverageLines !== undefined && !Array.isArray(body.acceptedOverageLines))) {
    throw new ApiRouteError("BACKOFFICE_ACCEPTED_OVERAGE_INVOICE_PAYLOAD_INVALID", 400);
  }
  const rawSalesOrderLines = Array.isArray(body.lines) ? body.lines : [];
  const rawAcceptedOverageLines = Array.isArray(body.acceptedOverageLines)
    ? body.acceptedOverageLines : [];
  if (rawSalesOrderLines.length === 0 && rawAcceptedOverageLines.length === 0) {
    throw new ApiRouteError("BACKOFFICE_SALES_INVOICE_LINES_REQUIRED", 400);
  }
  const lines = rawSalesOrderLines.map((raw) => {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      throw new ApiRouteError("BACKOFFICE_SALES_INVOICE_LINE_INVALID", 400);
    }
    const line = raw as JsonObject;
    const quantityUom = Number(line.quantityUom);
    const unitPrice = Number(line.unitPrice);
    const discountAmount = Number(line.discountAmount ?? 0);
    if (!Number.isFinite(quantityUom) || quantityUom <= 0 || !Number.isFinite(unitPrice) ||
      unitPrice < 0 || !Number.isFinite(discountAmount) || discountAmount < 0) {
      throw new ApiRouteError("BACKOFFICE_SALES_INVOICE_LINE_INVALID", 400);
    }
    return {
      salesOrderLineId: requiredUuid(line, "salesOrderLineId"),
      quantityUom,
      unitPrice,
      discountAmount,
      taxApplied: line.taxApplied === true,
    };
  });
  const acceptedOverageLines = rawAcceptedOverageLines.map((raw) => {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      throw new ApiRouteError("BACKOFFICE_ACCEPTED_OVERAGE_INVOICE_PAYLOAD_INVALID", 400);
    }
    const line = raw as JsonObject;
    if (Object.keys(line).some((key) => !["discrepancyLineId", "quantityUom"].includes(key))) {
      throw new ApiRouteError("BACKOFFICE_ACCEPTED_OVERAGE_INVOICE_COMMERCIAL_IMMUTABLE", 400);
    }
    const quantityUom = Number(line.quantityUom);
    if (!Number.isFinite(quantityUom) || quantityUom <= 0) {
      throw new ApiRouteError("BACKOFFICE_ACCEPTED_OVERAGE_INVOICE_PAYLOAD_INVALID", 400);
    }
    return {
      discrepancyLineId: requiredUuid(line, "discrepancyLineId"),
      quantityUom,
    };
  });
  const deliveryFeeAmount = Number(body.deliveryFeeAmount ?? 0);
  if (!Number.isFinite(deliveryFeeAmount) || deliveryFeeAmount < 0) {
    throw new ApiRouteError("BACKOFFICE_INVOICE_DELIVERY_FEE_INVALID", 400);
  }
  return {
    invoiceType: "REGULAR",
    invoiceDate: dateValue(body.invoiceDate, "BACKOFFICE_SALES_INVOICE_DATE_INVALID"),
    dueDate: dateValue(body.dueDate, "BACKOFFICE_SALES_INVOICE_DUE_DATE_INVALID"),
    paymentTermId: null,
    deliveryFeeAmount,
    notes: typeof body.notes === "string" ? body.notes.trim().slice(0, 1000) || null : null,
    lines,
    acceptedOverageLines,
  };
}

export function throwBackofficeInvoiceError(error: { code?: string; message?: string } | null): never {
  const message = error?.message ?? "";
  const codes = [
    "CUSTOM_PERMISSION_DENIED", "BACKOFFICE_SALES_ORDER_NOT_FOUND",
    "BACKOFFICE_SALES_ORDER_NOT_INVOICEABLE", "BACKOFFICE_SALES_INVOICE_NOT_FOUND",
    "BACKOFFICE_SALES_INVOICE_NOT_EDITABLE", "BACKOFFICE_SALES_INVOICE_NOT_CANCELABLE",
    "BACKOFFICE_SALES_INVOICE_LINES_REQUIRED", "BACKOFFICE_SALES_INVOICE_LINE_INVALID",
    "BACKOFFICE_SALES_INVOICE_LINE_DUPLICATE", "BACKOFFICE_SALES_INVOICE_QUANTITY_EXCEEDS_AVAILABLE",
    "BACKOFFICE_SALES_INVOICE_DUE_DATE_INVALID", "BACKOFFICE_SALES_INVOICE_DUE_DATE_CONFLICT",
    "BACKOFFICE_INVOICE_DELIVERY_FEE_INVALID", "BACKOFFICE_INVOICE_DELIVERY_FEE_EXCEEDS_ORDER",
    "INVOICE_DISCOUNT_EXCEEDS_LINE_TOTAL", "BACKOFFICE_SALES_INVOICE_PERIOD_NOT_OPEN",
    "BACKOFFICE_ACCEPTED_OVERAGE_INVOICE_PAYLOAD_INVALID",
    "BACKOFFICE_ACCEPTED_OVERAGE_INVOICE_COMMERCIAL_IMMUTABLE",
    "BACKOFFICE_ACCEPTED_OVERAGE_INVOICE_QUANTITY_EXCEEDS_AVAILABLE",
    "BACKOFFICE_ACCEPTED_OVERAGE_INVOICE_RECONCILIATION_FAILED",
    "BACKOFFICE_SALES_INVOICE_POST_PAYLOAD_INVALID", "FINAL_BACKOFFICE_SALES_INVOICE_IMMUTABLE",
    "MASTER_VERSION_CONFLICT", "IDEMPOTENCY_PAYLOAD_CONFLICT", "CANCEL_REASON_REQUIRED",
  ];
  const known = codes.find((code) => message.includes(code));
  if (known) {
    const status = known === "BACKOFFICE_SALES_INVOICE_NOT_FOUND" || known === "BACKOFFICE_SALES_ORDER_NOT_FOUND" ? 404
      : known === "CUSTOM_PERMISSION_DENIED" ? 403
        : ["MASTER_VERSION_CONFLICT", "IDEMPOTENCY_PAYLOAD_CONFLICT", "FINAL_BACKOFFICE_SALES_INVOICE_IMMUTABLE"].includes(known) ? 409 : 400;
    throw new ApiRouteError(known, status);
  }
  if (error?.code === "42501") throw new ApiRouteError("FORBIDDEN", 403);
  throw new ApiRouteError(message || "BACKOFFICE_SALES_INVOICE_OPERATION_FAILED", 500);
}
