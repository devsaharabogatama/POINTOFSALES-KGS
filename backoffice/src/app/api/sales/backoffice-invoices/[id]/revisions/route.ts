import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject, uuidValue } from "@/lib/master-data";
import {
  InvoiceCorrectionCommandError,
  parseInvoiceCorrectionCommand,
} from "@/lib/backoffice-invoice-correction-command";
import { throwBackofficeInvoiceError } from "@/lib/backoffice-sales-invoice";

type Context = { params: Promise<{ id: string }> };

export async function POST(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request);
    await requireActiveCompany(caller);
    const { id } = await params;
    const invoiceId = uuidValue(id, "BACKOFFICE_SALES_INVOICE_ID_INVALID");
    const command = parseInvoiceCorrectionCommand(await readJsonObject(request));
    if (command.kind !== "INVOICE_REVISION") {
      throw new InvoiceCorrectionCommandError("INVOICE_REVISION_COMMAND_REQUIRED");
    }
    if (command.invoiceId !== invoiceId) {
      throw new InvoiceCorrectionCommandError("INVOICE_REVISION_ROUTE_ID_MISMATCH");
    }
    const { data, error } = await caller.client.rpc("post_backoffice_invoice_revision", {
      p_command: command,
    });
    if (error) throwBackofficeInvoiceError(error);
    return Response.json(data);
  } catch (error) {
    return apiError(error);
  }
}
