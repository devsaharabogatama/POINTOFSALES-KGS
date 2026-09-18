import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject, uuidValue } from "@/lib/master-data";
import { requiredDate, returnExpectedVersion, returnOperationId, throwBackofficeReturnError } from "@/lib/backoffice-sales-return";
type Context = { params: Promise<{ id: string }> };
export async function POST(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request); await requireActiveCompany(caller); const { id } = await params; const body = await readJsonObject(request);
    const result = await caller.client.rpc("reverse_backoffice_sales_customer_refund", {
      p_refund_id: uuidValue(id, "CUSTOMER_REFUND_ID_INVALID"), p_expected_version: returnExpectedVersion(body), p_operation_id: returnOperationId(body),
      p_reversal_date: requiredDate(body, "reversalDate", "CUSTOMER_REFUND_REVERSAL_DATE_INVALID"), p_reason: typeof body.reason === "string" ? body.reason.trim().slice(0, 1000) : "",
    });
    if (result.error) throwBackofficeReturnError(result.error); return Response.json(result.data);
  } catch (error) { return apiError(error); }
}
