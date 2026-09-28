import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject, uuidValue } from "@/lib/master-data";
import {
  invoiceExpectedPriceRevision,
  invoiceExpectedVersion,
  invoiceOperationId,
  parsePostedInvoicePriceCorrectionLines,
  throwBackofficeInvoiceError,
} from "@/lib/backoffice-sales-invoice";

type Context = { params: Promise<{ id: string }> };

export async function POST(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request);
    await requireActiveCompany(caller);
    const { id } = await params;
    const body = await readJsonObject(request);
    const { data, error } = await caller.client.rpc("post_backoffice_sales_invoice_price_correction", {
      p_invoice_id: uuidValue(id, "BACKOFFICE_SALES_INVOICE_ID_INVALID"),
      p_expected_version: invoiceExpectedVersion(body),
      p_expected_price_revision: invoiceExpectedPriceRevision(body),
      p_operation_id: invoiceOperationId(body),
      p_lines: parsePostedInvoicePriceCorrectionLines(body),
    });
    if (error) throwBackofficeInvoiceError(error);
    return Response.json(data);
  } catch (error) {
    return apiError(error);
  }
}
