import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject, uuidValue } from "@/lib/master-data";
import {
  expectedVersion,
  operationId,
  parseBackofficeSalesOrderPayload,
  throwBackofficeSalesOrderError,
} from "@/lib/backoffice-sales-order";
import { salesReturnAdjustmentMap } from "@/lib/sales-return-commercial";

type Context = { params: Promise<{ id: string }> };

export async function GET(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request);
    await requireActiveCompany(caller);
    const { id } = await params;
    const orderId = uuidValue(id, "BACKOFFICE_SALES_ORDER_ID_INVALID");
    const [{ data, error }, links, adjustments] = await Promise.all([
      caller.client.rpc("get_backoffice_sales_order", { p_order_id: orderId }),
      caller.client.rpc("get_backoffice_sales_return_links", { p_sales_order_id: orderId }),
      caller.client.rpc("get_sales_return_commercial_adjustments"),
    ]);
    if (error) throwBackofficeSalesOrderError(error);
    if (links.error) throwBackofficeSalesOrderError(links.error);
    const adjustmentMissing = adjustments.error?.code === "PGRST202"
      || Boolean(adjustments.error?.message?.includes("get_sales_return_commercial_adjustments"));
    if (adjustments.error && !adjustmentMissing) throwBackofficeSalesOrderError(adjustments.error);
    const adjustment = salesReturnAdjustmentMap(adjustments.data).get(`BACKOFFICE:${orderId}`) ?? null;
    return Response.json({ ...data, data: { ...data?.data,
      returns: links.data?.data ?? [], returnAdjustment: adjustment } });
  } catch (error) {
    return apiError(error);
  }
}

export async function PUT(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request);
    await requireActiveCompany(caller);
    const { id } = await params;
    const body = await readJsonObject(request);
    const { data, error } = await caller.client.rpc("save_backoffice_sales_order_draft", {
      p_order_id: uuidValue(id, "BACKOFFICE_SALES_ORDER_ID_INVALID"),
      p_expected_version: expectedVersion(body),
      p_operation_id: operationId(body),
      p_payload: parseBackofficeSalesOrderPayload(body),
    });
    if (error) throwBackofficeSalesOrderError(error);
    return Response.json(data);
  } catch (error) {
    return apiError(error);
  }
}
