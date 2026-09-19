import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject } from "@/lib/master-data";
import {
  operationId,
  parseBackofficeSalesOrderPayload,
  throwBackofficeSalesOrderError,
} from "@/lib/backoffice-sales-order";
import { salesReturnAdjustmentMap } from "@/lib/sales-return-commercial";

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
    const [{ data, error }, links, adjustments] = await Promise.all([
      caller.client.rpc("get_backoffice_sales_orders_v3", {
      p_document_kind: documentKind,
      p_fulfillment_status: fulfillmentStatus,
      p_invoice_status: invoiceStatus,
      p_date_basis: dateBasis,
      p_date_from: dateFrom,
      p_date_to: dateTo,
      p_search: search,
      p_limit: 100,
      }),
      caller.client.rpc("get_backoffice_sales_return_links", { p_sales_order_id: null }),
      caller.client.rpc("get_sales_return_commercial_adjustments"),
    ]);
    if (error) throwBackofficeSalesOrderError(error);
    if (links.error) throwBackofficeSalesOrderError(links.error);
    const adjustmentMissing = adjustments.error?.code === "PGRST202"
      || Boolean(adjustments.error?.message?.includes("get_sales_return_commercial_adjustments"));
    if (adjustments.error && !adjustmentMissing) throwBackofficeSalesOrderError(adjustments.error);
    const adjustmentsBySource = salesReturnAdjustmentMap(adjustments.data);
    const linksByOrder = new Map<string, unknown[]>();
    for (const link of links.data?.data ?? []) {
      const salesOrderId = String(link.salesOrderId ?? "");
      linksByOrder.set(salesOrderId, [...(linksByOrder.get(salesOrderId) ?? []), link]);
    }
    return Response.json({
      ...data,
      data: (data?.data ?? []).map((order: { id: string }) => ({
        ...order,
        returns: linksByOrder.get(order.id) ?? [],
        returnAdjustment: adjustmentsBySource.get(`BACKOFFICE:${order.id}`) ?? null,
      })),
    });
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
