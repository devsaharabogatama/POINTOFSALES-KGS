import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject, uuidValue } from "@/lib/master-data";
import {
  expectedVersion,
  operationId,
  throwBackofficeSalesOrderError,
} from "@/lib/backoffice-sales-order";

type Context = { params: Promise<{ id: string }> };

export async function POST(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request);
    await requireActiveCompany(caller);
    const { id } = await params;
    const body = await readJsonObject(request);
    const action = typeof body.action === "string" ? body.action.toUpperCase() : "";
    const rpc = action === "SEND" ? "send_backoffice_sales_quotation"
      : action === "CONFIRM" ? "confirm_backoffice_sales_order"
        : action === "CANCEL" ? "cancel_backoffice_sales_order" : null;
    if (!rpc) throw new ApiRouteError("BACKOFFICE_SALES_ORDER_ACTION_INVALID", 400);
    const args: Record<string, unknown> = {
      p_order_id: uuidValue(id, "BACKOFFICE_SALES_ORDER_ID_INVALID"),
      p_expected_version: expectedVersion(body),
      p_operation_id: operationId(body),
    };
    if (action === "CANCEL") {
      if (typeof body.reason !== "string" || !body.reason.trim()) {
        throw new ApiRouteError("CANCEL_REASON_REQUIRED", 400);
      }
      args.p_reason = body.reason.trim().slice(0, 1000);
    }
    const { data, error } = await caller.client.rpc(rpc, args);
    if (error) throwBackofficeSalesOrderError(error);
    return Response.json(data);
  } catch (error) {
    return apiError(error);
  }
}
