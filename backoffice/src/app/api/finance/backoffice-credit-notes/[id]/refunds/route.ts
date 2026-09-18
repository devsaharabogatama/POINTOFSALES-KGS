import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject, uuidValue } from "@/lib/master-data";
import { requiredDate, returnExpectedVersion, returnOperationId, throwBackofficeReturnError } from "@/lib/backoffice-sales-return";
type Context = { params: Promise<{ id: string }> };
export async function POST(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request); await requireActiveCompany(caller); const { id } = await params; const body = await readJsonObject(request);
    const amount = Number(body.amount); if (!Number.isFinite(amount) || amount <= 0) throw new ApiRouteError("CUSTOMER_REFUND_AMOUNT_INVALID", 400);
    const result = await caller.client.rpc("post_backoffice_sales_customer_refund", {
      p_credit_note_id: uuidValue(id, "CREDIT_NOTE_ID_INVALID"), p_expected_version: returnExpectedVersion(body), p_operation_id: returnOperationId(body),
      p_refund_date: requiredDate(body, "refundDate", "CUSTOMER_REFUND_DATE_INVALID"), p_amount: amount,
      p_payment_method_id: uuidValue(String(body.paymentMethodId ?? ""), "CUSTOMER_REFUND_PAYMENT_METHOD_INVALID"),
      p_reference_no: typeof body.referenceNo === "string" ? body.referenceNo.trim().slice(0, 500) || null : null,
      p_evidence_url: typeof body.evidenceUrl === "string" ? body.evidenceUrl.trim() || null : null,
      p_notes: typeof body.notes === "string" ? body.notes.trim().slice(0, 2000) || null : null,
    });
    if (result.error) throwBackofficeReturnError(result.error); return Response.json(result.data);
  } catch (error) { return apiError(error); }
}
