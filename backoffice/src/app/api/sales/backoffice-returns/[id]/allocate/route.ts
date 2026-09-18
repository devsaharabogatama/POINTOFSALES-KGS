import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject, uuidValue } from "@/lib/master-data";
import { parseReturnAllocations, returnExpectedVersion, returnOperationId, throwBackofficeReturnError } from "@/lib/backoffice-sales-return";

type Context = { params: Promise<{ id: string }> };
export async function POST(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request); await requireActiveCompany(caller);
    const { id } = await params; const body = await readJsonObject(request);
    const result = await caller.client.rpc("allocate_backoffice_sales_return_invoices", {
      p_return_id: uuidValue(id, "BACKOFFICE_SALES_RETURN_ID_INVALID"), p_expected_version: returnExpectedVersion(body),
      p_operation_id: returnOperationId(body), p_allocations: parseReturnAllocations(body),
    });
    if (result.error) throwBackofficeReturnError(result.error);
    return Response.json(result.data);
  } catch (error) { return apiError(error); }
}
