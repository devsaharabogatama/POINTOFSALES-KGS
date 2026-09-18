import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject, uuidValue } from "@/lib/master-data";
import { returnExpectedVersion, returnOperationId, throwBackofficeReturnError } from "@/lib/backoffice-sales-return";
type Context = { params: Promise<{ id: string }> };
export async function POST(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request); await requireActiveCompany(caller); const { id } = await params; const body = await readJsonObject(request);
    const result = await caller.client.rpc("post_backoffice_sales_credit_note", { p_credit_note_id: uuidValue(id, "CREDIT_NOTE_ID_INVALID"), p_expected_version: returnExpectedVersion(body), p_operation_id: returnOperationId(body) });
    if (result.error) throwBackofficeReturnError(result.error); return Response.json(result.data);
  } catch (error) { return apiError(error); }
}
