import { ApiRouteError } from "@/lib/server-auth";
import { uuidValue } from "@/lib/master-data";

type JsonObject = Record<string, unknown>;

function dateValue(value: unknown, code: string) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new ApiRouteError(code, 400);
  }
  return value;
}

function requiredUuid(body: JsonObject, field: string) {
  const value = body[field];
  if (typeof value !== "string") {
    throw new ApiRouteError(`${field.toUpperCase()}_REQUIRED`, 400);
  }
  return uuidValue(value, `${field.toUpperCase()}_INVALID`);
}

export function operationId(body: JsonObject) {
  return requiredUuid(body, "operationId");
}

export function expectedVersion(body: JsonObject) {
  if (!Number.isSafeInteger(body.masterVersion) || Number(body.masterVersion) < 1) {
    throw new ApiRouteError("MASTER_VERSION_REQUIRED", 400);
  }
  return Number(body.masterVersion);
}

export function parseBackofficeSalesOrderPayload(body: JsonObject) {
  if (!Array.isArray(body.lines) || body.lines.length === 0) {
    throw new ApiRouteError("BACKOFFICE_SALES_ORDER_LINES_REQUIRED", 400);
  }
  const isTempo = body.isTempo === true;
  const dueDate = body.dueDate;
  if (isTempo && (typeof dueDate !== "string" || !dueDate)) {
    throw new ApiRouteError("BACKOFFICE_SALES_ORDER_DUE_DATE_REQUIRED", 400);
  }
  if (body.notes !== null && body.notes !== undefined && typeof body.notes !== "string") {
    throw new ApiRouteError("BACKOFFICE_SALES_ORDER_NOTES_INVALID", 400);
  }
  const lines = body.lines.map((raw, index) => {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      throw new ApiRouteError(`BACKOFFICE_SALES_ORDER_LINE_${index + 1}_INVALID`, 400);
    }
    const line = raw as JsonObject;
    const quantity = Number(line.quantity);
    if (!Number.isFinite(quantity) || quantity <= 0) {
      throw new ApiRouteError("BACKOFFICE_SALES_ORDER_QUANTITY_INVALID", 400);
    }
    const discountType = typeof line.lineDiscountType === "string"
      ? line.lineDiscountType.trim().toUpperCase()
      : "";
    if (discountType && !["AMOUNT", "PERCENT"].includes(discountType)) {
      throw new ApiRouteError("LINE_DISCOUNT_TYPE_INVALID", 400);
    }
    const discountInput = Number(line.lineDiscountInput ?? 0);
    if (!Number.isFinite(discountInput) || discountInput < 0 ||
      (discountType === "PERCENT" && discountInput > 100)) {
      throw new ApiRouteError("LINE_DISCOUNT_INVALID", 400);
    }
    const hasOverride = line.overrideUnitPrice !== null && line.overrideUnitPrice !== undefined;
    const overrideUnitPrice = hasOverride ? Number(line.overrideUnitPrice) : null;
    if (hasOverride && (!Number.isFinite(overrideUnitPrice) || Number(overrideUnitPrice) < 0)) {
      throw new ApiRouteError("BACKOFFICE_PRICE_OVERRIDE_INVALID", 400);
    }
    return {
      productUomId: requiredUuid(line, "productUomId"),
      quantity,
      lineDiscountType: discountType || null,
      lineDiscountInput: discountType ? discountInput : null,
      ...(hasOverride ? { overrideUnitPrice } : {}),
    };
  });
  if (new Set(lines.map((line) => line.productUomId)).size !== lines.length) {
    throw new ApiRouteError("BACKOFFICE_SALES_ORDER_PRODUCT_UOM_DUPLICATE", 400);
  }
  const globalDiscount = Number(body.globalDiscount ?? 0);
  const deliveryFeeAmount = Number(body.deliveryFeeAmount ?? 0);
  const roundingDirection = typeof body.roundingDirection === "string"
    ? body.roundingDirection.trim().toUpperCase()
    : "NONE";
  if (!Number.isFinite(deliveryFeeAmount) || deliveryFeeAmount < 0) {
    throw new ApiRouteError("BACKOFFICE_DELIVERY_FEE_INVALID", 400);
  }
  if (!Number.isFinite(globalDiscount) || globalDiscount < 0 ||
    !["NONE", "DOWN", "UP"].includes(roundingDirection)) {
    throw new ApiRouteError("BACKOFFICE_SALES_COMMERCIAL_INPUT_INVALID", 400);
  }
  const revisionReason = typeof body.revisionReason === "string"
    ? body.revisionReason.trim().slice(0, 1000)
    : "";
  return {
    storeId: requiredUuid(body, "storeId"),
    warehouseId: requiredUuid(body, "warehouseId"),
    customerId: requiredUuid(body, "customerId"),
    selectedPricelistId: body.selectedPricelistId
      ? requiredUuid(body, "selectedPricelistId")
      : null,
    orderDate: dateValue(body.orderDate, "BACKOFFICE_SALES_ORDER_DATE_INVALID"),
    plannedDeliveryDate: dateValue(
      body.plannedDeliveryDate,
      "BACKOFFICE_SALES_ORDER_DELIVERY_DATE_INVALID",
    ),
    isTempo,
    dueDate: dueDate ? dateValue(dueDate, "BACKOFFICE_SALES_ORDER_DUE_DATE_INVALID") : null,
    currencyCode: "IDR",
    notes: typeof body.notes === "string" ? body.notes.trim().slice(0, 1000) || null : null,
    globalDiscount,
    deliveryFeeAmount,
    deliveryFeeInvoiceDisplayMode: "SHOW_SEPARATE",
    roundingDirection,
    roundingIncrement: 100,
    ...(revisionReason ? { revisionReason } : {}),
    lines,
  };
}

export function throwBackofficeSalesOrderError(
  error: { code?: string; message?: string } | null,
): never {
  const message = error?.message ?? "";
  const known = [
    "CUSTOM_PERMISSION_DENIED",
    "BACKOFFICE_SALES_ORDER_NOT_FOUND",
    "BACKOFFICE_SALES_ORDER_NOT_DRAFT",
    "BACKOFFICE_SALES_ORDER_EDIT_STATE_INVALID",
    "BACKOFFICE_SALES_ORDER_REVISION_REASON_REQUIRED",
    "BACKOFFICE_SALES_ORDER_REVISION_REQUIRES_RETURN_OR_FULFILLMENT_SYNC",
    "BACKOFFICE_SALES_ORDER_STATUS_INVALID",
    "BACKOFFICE_SALES_DOCUMENT_KIND_INVALID",
    "BACKOFFICE_SALES_FULFILLMENT_STATUS_INVALID",
    "BACKOFFICE_SALES_FILTER_INVALID",
    "BACKOFFICE_SALES_ORDER_BUSINESS_DATE_OR_LINE_INVALID",
    "BACKOFFICE_SALES_ORDER_LINE_INVALID",
    "BACKOFFICE_SALES_ORDER_TRANSITION_INPUT_REQUIRED",
    "BACKOFFICE_QUOTATION_SEND_STATE_INVALID",
    "BACKOFFICE_SALES_CONFIRM_STATE_INVALID",
    "BACKOFFICE_SALES_CANCEL_STATE_INVALID",
    "BACKOFFICE_SALES_PRICELIST_MIXED",
    "BACKOFFICE_SALES_COMMERCIAL_INPUT_INVALID",
    "BACKOFFICE_PRICE_OVERRIDE_INVALID",
    "LINE_DISCOUNT_TYPE_INVALID",
    "LINE_DISCOUNT_INVALID",
    "LINE_DISCOUNT_EXCEEDS_LINE_TOTAL",
    "GLOBAL_DISCOUNT_EXCEEDS_SALE_TOTAL",
    "INVALID_PRICELIST_SELECTION",
    "PRICELIST_NOT_ELIGIBLE",
    "ACTIVE_STORE_NOT_FOUND",
    "ACTIVE_WAREHOUSE_NOT_FOUND",
    "ACTIVE_CUSTOMER_NOT_FOUND",
    "CANCEL_REASON_REQUIRED",
    "MASTER_VERSION_CONFLICT",
    "IDEMPOTENCY_PAYLOAD_CONFLICT",
  ].find((code) => message.includes(code));
  if (known) {
    const status = known === "BACKOFFICE_SALES_ORDER_NOT_FOUND" ? 404
      : known === "CUSTOM_PERMISSION_DENIED" ? 403
        : [
            "MASTER_VERSION_CONFLICT",
            "IDEMPOTENCY_PAYLOAD_CONFLICT",
            "BACKOFFICE_SALES_ORDER_NOT_DRAFT",
            "BACKOFFICE_QUOTATION_SEND_STATE_INVALID",
            "BACKOFFICE_SALES_CONFIRM_STATE_INVALID",
            "BACKOFFICE_SALES_CANCEL_STATE_INVALID",
          ].includes(known) ? 409 : 400;
    throw new ApiRouteError(known, status);
  }
  if (error?.code === "42501") throw new ApiRouteError("FORBIDDEN", 403);
  throw new ApiRouteError(message || "BACKOFFICE_SALES_ORDER_OPERATION_FAILED", 500);
}
