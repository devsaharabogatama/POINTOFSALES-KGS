import { ApiRouteError } from "@/lib/server-auth";
import { optionalText, requiredVersion, uuidValue } from "@/lib/master-data";

type JsonObject = Record<string, unknown>;

function uuid(body: JsonObject, field: string) {
  const value = body[field];
  if (typeof value !== "string")
    throw new ApiRouteError(`${field.toUpperCase()}_REQUIRED`, 400);
  return uuidValue(value, `${field.toUpperCase()}_INVALID`);
}

function date(body: JsonObject, field: string, required: boolean) {
  const value = body[field];
  if ((value === null || value === undefined || value === "") && !required)
    return null;
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value))
    throw new ApiRouteError(`${field.toUpperCase()}_INVALID`, 400);
  return value;
}

function positive(value: unknown, code: string, allowZero = false) {
  const number = Number(value);
  if (!Number.isFinite(number) || (allowZero ? number < 0 : number <= 0))
    throw new ApiRouteError(code, 400);
  return number;
}

export function parseSupplierOrderBody(body: JsonObject, updating = false) {
  if (!Array.isArray(body.lines) || body.lines.length === 0)
    throw new ApiRouteError("SUPPLIER_ORDER_LINES_REQUIRED", 400);
  if (!Array.isArray(body.allocations) || body.allocations.length === 0)
    throw new ApiRouteError("SUPPLIER_ORDER_ALLOCATIONS_REQUIRED", 400);
  const lines = body.lines.map((raw, index) => {
    if (!raw || typeof raw !== "object" || Array.isArray(raw))
      throw new ApiRouteError(`SUPPLIER_ORDER_LINE_${index + 1}_INVALID`, 400);
    const line = raw as JsonObject;
    return {
      clientLineKey: uuid(line, "clientLineKey"),
      productId: uuid(line, "productId"),
      uomId: uuid(line, "uomId"),
      quantity: positive(line.quantity, "SUPPLIER_ORDER_QUANTITY_INVALID"),
      estimatedUnitPrice: positive(
        line.estimatedUnitPrice,
        "SUPPLIER_ORDER_PRICE_INVALID",
        true,
      ),
    };
  });
  const allocations = body.allocations.map((raw, index) => {
    if (!raw || typeof raw !== "object" || Array.isArray(raw))
      throw new ApiRouteError(
        `SUPPLIER_ORDER_ALLOCATION_${index + 1}_INVALID`,
        400,
      );
    const item = raw as JsonObject;
    return {
      orderLineKey: uuid(item, "orderLineKey"),
      requestLineId: uuid(item, "requestLineId"),
      allocatedBaseQty: positive(
        item.allocatedBaseQty,
        "SUPPLIER_ORDER_ALLOCATION_INVALID",
      ),
    };
  });
  return {
    masterVersion: updating ? requiredVersion(body) : null,
    storeId: uuid(body, "storeId"),
    destinationWarehouseId: uuid(body, "destinationWarehouseId"),
    supplierId: uuid(body, "supplierId"),
    orderDate: date(body, "orderDate", true),
    expectedDate: date(body, "expectedDate", false),
    notes: optionalText(body, "notes", { maxLength: 1000 }) ?? null,
    lines,
    allocations,
  };
}

export function supplierOrderRpcArgs(
  documentId: string | null,
  input: ReturnType<typeof parseSupplierOrderBody>,
) {
  return {
    p_document_id: documentId,
    p_master_version: input.masterVersion,
    p_store_id: input.storeId,
    p_destination_warehouse_id: input.destinationWarehouseId,
    p_supplier_id: input.supplierId,
    p_order_date: input.orderDate,
    p_expected_date: input.expectedDate,
    p_notes: input.notes,
    p_lines: input.lines,
    p_allocations: input.allocations,
  };
}

export function throwSupplierOrderError(
  error: { code?: string; message?: string } | null,
): never {
  const message = error?.message ?? "";
  const codes = [
    "CUSTOM_PERMISSION_DENIED",
    "PURCHASE_MANAGER_REQUIRED",
    "ACTIVE_STORE_NOT_FOUND",
    "ACTIVE_DESTINATION_WAREHOUSE_NOT_FOUND",
    "ACTIVE_SUPPLIER_NOT_FOUND",
    "SUPPLIER_ORDER_EXPECTED_DATE_INVALID",
    "SUPPLIER_ORDER_LINES_REQUIRED",
    "SUPPLIER_ORDER_ALLOCATIONS_REQUIRED",
    "ACTIVE_PURCHASE_PRODUCT_UOM_NOT_FOUND",
    "PURCHASE_UOM_REQUIRES_INTEGER",
    "PURCHASE_UOM_PRECISION_EXCEEDED",
    "ELIGIBLE_STOCK_REQUEST_LINE_NOT_FOUND",
    "ORDER_ALLOCATION_EXCEEDS_ORDERED_QUANTITY",
    "SUPPLIER_ORDER_NOT_FOUND",
    "SUPPLIER_ORDER_NOT_DRAFT",
    "SUPPLIER_ORDER_LINE_WITHOUT_REQUEST_ALLOCATION",
    "REQUEST_ALLOCATION_EXCEEDS_REQUESTED_QUANTITY",
    "MASTER_VERSION_CONFLICT",
  ].find((code) => message.includes(code));
  if (codes)
    throw new ApiRouteError(
      codes,
      ["CUSTOM_PERMISSION_DENIED", "PURCHASE_MANAGER_REQUIRED"].includes(codes)
        ? 403
        : ["MASTER_VERSION_CONFLICT", "SUPPLIER_ORDER_NOT_DRAFT"].includes(
              codes,
            )
          ? 409
          : 400,
    );
  if (error?.code === "42501") throw new ApiRouteError("FORBIDDEN", 403);
  throw new ApiRouteError(message || "SUPPLIER_ORDER_OPERATION_FAILED", 500);
}
