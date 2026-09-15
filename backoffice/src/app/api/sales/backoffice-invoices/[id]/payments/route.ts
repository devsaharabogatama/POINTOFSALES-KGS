import { apiError, requireActiveCompany, requireCaller, requirePermissionCapability } from "@/lib/server-auth";
import { readJsonObject, throwDatabaseError, uuidValue } from "@/lib/master-data";

type Context = { params: Promise<{ id: string }> };

function requiredDate(value: unknown) {
  const result = String(value ?? "");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(result)) throw new Error("CUSTOMER_RECEIPT_DATE_INVALID");
  return result;
}
function optionalText(value: unknown) {
  const result = String(value ?? "").trim();
  return result ? result.slice(0, 1000) : null;
}

export async function POST(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request);
    const companyId = await requireActiveCompany(caller);
    await requirePermissionCapability(caller, companyId, "finance.customer_receipts", "CREATE_DRAFT");
    await requirePermissionCapability(caller, companyId, "finance.customer_receipts", "POST");
    const { id } = await params;
    const body = await readJsonObject(request);
    const amount = Number(body.amount);
    if (!Number.isFinite(amount) || amount <= 0) throw new Error("CUSTOMER_RECEIPT_AMOUNT_INVALID");
    const evidenceUrl = optionalText(body.evidenceUrl);
    if (evidenceUrl && !evidenceUrl.toLowerCase().startsWith("https://")) {
      throw new Error("CUSTOMER_RECEIPT_EVIDENCE_MUST_USE_HTTPS");
    }
    const { data, error } = await caller.client.rpc("register_backoffice_sales_invoice_payment", {
      p_invoice_id: uuidValue(id, "BACKOFFICE_SALES_INVOICE_ID_INVALID"),
      p_operation_id: uuidValue(String(body.operationId ?? ""), "IDEMPOTENCY_KEY_REQUIRED"),
      p_receipt_date: requiredDate(body.receiptDate),
      p_payment_method_id: uuidValue(String(body.paymentMethodId ?? ""), "PAYMENT_METHOD_ID_INVALID"),
      p_amount: amount,
      p_reference_no: optionalText(body.referenceNo),
      p_evidence_url: evidenceUrl,
      p_notes: optionalText(body.notes),
    });
    if (error) throwDatabaseError(error);
    return Response.json(data, { status: 201 });
  } catch (error) { return apiError(error); }
}
