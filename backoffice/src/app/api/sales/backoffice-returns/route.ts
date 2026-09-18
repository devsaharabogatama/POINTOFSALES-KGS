import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject, uuidValue } from "@/lib/master-data";
import { parseReturnDraft, returnOperationId, throwBackofficeReturnError } from "@/lib/backoffice-sales-return";

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request); await requireActiveCompany(caller);
    const url = new URL(request.url);
    const result = await caller.client.rpc("get_backoffice_sales_returns", {
      p_status: url.searchParams.get("status") || null,
      p_search: url.searchParams.get("search") || null,
      p_limit: 100,
    });
    if (result.error) throwBackofficeReturnError(result.error);
    return Response.json(result.data);
  } catch (error) { return apiError(error); }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request); await requireActiveCompany(caller);
    const body = await readJsonObject(request);
    const salesOrderId = uuidValue(String(body.salesOrderId ?? ""), "BACKOFFICE_SALES_ORDER_ID_INVALID");
    const result = await caller.client.rpc("save_backoffice_sales_return_draft", {
      p_return_id: null, p_expected_version: null, p_operation_id: returnOperationId(body),
      p_sales_order_id: salesOrderId, p_payload: parseReturnDraft(body),
    });
    if (result.error) throwBackofficeReturnError(result.error);
    return Response.json(result.data, { status: 201 });
  } catch (error) { return apiError(error); }
}
