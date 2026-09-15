import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject, uuidValue } from "@/lib/master-data";
import {
  expectedVersion,
  operationId,
  parseBackofficeSalesOrderPayload,
  throwBackofficeSalesOrderError,
} from "@/lib/backoffice-sales-order";

type Context = { params: Promise<{ id: string }> };

export async function GET(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request);
    await requireActiveCompany(caller);
    const { id } = await params;
    const { data, error } = await caller.client.rpc("get_backoffice_sales_order", {
      p_order_id: uuidValue(id, "BACKOFFICE_SALES_ORDER_ID_INVALID"),
    });
    if (error) throwBackofficeSalesOrderError(error);
    return Response.json(data);
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
