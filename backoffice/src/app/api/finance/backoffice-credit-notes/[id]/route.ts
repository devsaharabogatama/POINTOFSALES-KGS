import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject, uuidValue } from "@/lib/master-data";
import { requiredDate, returnExpectedVersion, returnOperationId, throwBackofficeReturnError } from "@/lib/backoffice-sales-return";

type Context = { params: Promise<{ id: string }> };
export async function GET(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request); await requireActiveCompany(caller);
    const { id } = await params; const creditNoteId = uuidValue(id, "CREDIT_NOTE_ID_INVALID");
    const note = await caller.client.rpc("get_backoffice_sales_credit_note", { p_credit_note_id: creditNoteId });
    if (note.error) throwBackofficeReturnError(note.error);
    const refunds = await caller.client.rpc("get_backoffice_sales_credit_note_refunds", { p_credit_note_id: creditNoteId });
    if (refunds.error && !refunds.error.message?.includes("CUSTOM_PERMISSION_DENIED")) throwBackofficeReturnError(refunds.error);
    let paymentContext = null;
    if (!refunds.error && note.data?.data?.sourceInvoiceId) {
      const payment = await caller.client.rpc("get_backoffice_sales_invoice_payment_context", { p_invoice_id: note.data.data.sourceInvoiceId });
      if (payment.error) throwBackofficeReturnError(payment.error); paymentContext = payment.data;
    }
    return Response.json({ ...note.data, refunds: refunds.error ? null : refunds.data, paymentContext });
  } catch (error) { return apiError(error); }
}

export async function PUT(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request); await requireActiveCompany(caller);
    const { id } = await params; const body = await readJsonObject(request);
    const amount = Number(body.deliveryFeeAmount ?? 0);
    if (!Number.isFinite(amount) || amount < 0 || typeof body.reason !== "string" || !body.reason.trim()) throw new ApiRouteError("CREDIT_NOTE_DRAFT_INPUT_INVALID", 400);
    const result = await caller.client.rpc("update_backoffice_sales_credit_note_draft", {
      p_credit_note_id: uuidValue(id, "CREDIT_NOTE_ID_INVALID"), p_expected_version: returnExpectedVersion(body),
      p_operation_id: returnOperationId(body), p_credit_note_date: requiredDate(body, "creditNoteDate", "CREDIT_NOTE_DATE_INVALID"),
      p_delivery_fee_amount: amount, p_reason: body.reason.trim().slice(0, 1000),
    });
    if (result.error) throwBackofficeReturnError(result.error); return Response.json(result.data);
  } catch (error) { return apiError(error); }
}
