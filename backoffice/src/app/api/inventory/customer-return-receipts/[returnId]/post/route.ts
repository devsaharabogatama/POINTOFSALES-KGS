import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject, uuidValue } from "@/lib/master-data";
import { parseReturnReceipt, requiredDate, returnExpectedVersion, returnOperationId, throwBackofficeReturnError } from "@/lib/backoffice-sales-return";

type Context = { params: Promise<{ returnId: string }> };
export async function POST(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request); await requireActiveCompany(caller);
    const { returnId } = await params; const body = await readJsonObject(request);
    const result = await caller.client.rpc("post_backoffice_sales_return_receipt", {
      p_return_id: uuidValue(returnId, "BACKOFFICE_SALES_RETURN_ID_INVALID"), p_expected_version: returnExpectedVersion(body),
      p_operation_id: returnOperationId(body), p_receipt_date: requiredDate(body, "receiptDate", "BACKOFFICE_SALES_RETURN_RECEIPT_DATE_INVALID"),
      p_lines: parseReturnReceipt(body), p_notes: typeof body.notes === "string" ? body.notes.trim().slice(0, 2000) || null : null,
    });
    if (result.error) throwBackofficeReturnError(result.error);
    return Response.json(result.data);
  } catch (error) { return apiError(error); }
}
