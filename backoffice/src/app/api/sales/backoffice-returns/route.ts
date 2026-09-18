import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject, uuidValue } from "@/lib/master-data";
import { parseRetainedRetailReturnDraft, parseReturnDraft, returnOperationId, throwBackofficeReturnError } from "@/lib/backoffice-sales-return";

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
    const retainedRetail = body.sourceKind === "RETAINED_RETAIL";
    const result = retainedRetail
      ? await caller.client.rpc("save_retained_retail_backoffice_return_draft", {
        p_return_id: null, p_expected_version: null, p_operation_id: returnOperationId(body),
        p_sales_id: uuidValue(String(body.retailSalesId ?? ""), "RETAINED_RETAIL_SALES_ID_INVALID"),
        p_payload: parseRetainedRetailReturnDraft(body),
      })
      : await caller.client.rpc("save_backoffice_sales_return_draft", {
        p_return_id: null, p_expected_version: null, p_operation_id: returnOperationId(body),
        p_sales_order_id: uuidValue(String(body.salesOrderId ?? ""), "BACKOFFICE_SALES_ORDER_ID_INVALID"),
        p_payload: parseReturnDraft(body),
      });
    if (result.error) throwBackofficeReturnError(result.error);
    return Response.json(result.data, { status: 201 });
  } catch (error) { return apiError(error); }
}
