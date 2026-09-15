import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject } from "@/lib/master-data";
import {
  operationId,
  parseBackofficeSalesOrderPayload,
  throwBackofficeSalesOrderError,
} from "@/lib/backoffice-sales-order";

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request);
    await requireActiveCompany(caller);
    const url = new URL(request.url);
    const documentKind = url.searchParams.get("documentKind") || null;
    const fulfillmentStatus = url.searchParams.get("fulfillmentStatus") || null;
    const invoiceStatus = url.searchParams.get("invoiceStatus") || null;
    const dateBasis = url.searchParams.get("dateBasis") || "ORDER_DATE";
    const dateFrom = url.searchParams.get("dateFrom") || null;
    const dateTo = url.searchParams.get("dateTo") || null;
    const search = url.searchParams.get("search") || null;
    const { data, error } = await caller.client.rpc("get_backoffice_sales_orders_v3", {
      p_document_kind: documentKind,
      p_fulfillment_status: fulfillmentStatus,
      p_invoice_status: invoiceStatus,
      p_date_basis: dateBasis,
      p_date_from: dateFrom,
      p_date_to: dateTo,
      p_search: search,
      p_limit: 100,
    });
    if (error) throwBackofficeSalesOrderError(error);
    return Response.json(data);
  } catch (error) {
    return apiError(error);
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request);
    await requireActiveCompany(caller);
    const body = await readJsonObject(request);
    const { data, error } = await caller.client.rpc("save_backoffice_sales_order_draft", {
      p_order_id: null,
      p_expected_version: null,
      p_operation_id: operationId(body),
      p_payload: parseBackofficeSalesOrderPayload(body),
    });
    if (error) throwBackofficeSalesOrderError(error);
    return Response.json(data, { status: 201 });
  } catch (error) {
    return apiError(error);
  }
}
