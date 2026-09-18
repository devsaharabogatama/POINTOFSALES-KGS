import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject, uuidValue } from "@/lib/master-data";
import { returnExpectedVersion, returnOperationId, throwBackofficeReturnError } from "@/lib/backoffice-sales-return";

type Context = { params: Promise<{ id: string }> };
export async function POST(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request); await requireActiveCompany(caller);
    const { id } = await params; const body = await readJsonObject(request);
    const action = typeof body.action === "string" ? body.action.toUpperCase() : "";
    const args = { p_return_id: uuidValue(id, "BACKOFFICE_SALES_RETURN_ID_INVALID"), p_expected_version: returnExpectedVersion(body), p_operation_id: returnOperationId(body) };
    const result = action === "SUBMIT" ? await caller.client.rpc("submit_backoffice_sales_return", args)
      : action === "APPROVE" ? await caller.client.rpc("approve_backoffice_sales_return", args)
        : action === "CANCEL" ? await caller.client.rpc("cancel_backoffice_sales_return", { ...args, p_reason: typeof body.reason === "string" ? body.reason.trim() : "" })
          : (() => { throw new ApiRouteError("BACKOFFICE_SALES_RETURN_OPERATION_INVALID", 400); })();
    if (result.error) throwBackofficeReturnError(result.error);
    return Response.json(result.data);
  } catch (error) { return apiError(error); }
}
