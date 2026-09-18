import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { throwBackofficeReturnError } from "@/lib/backoffice-sales-return";

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request); await requireActiveCompany(caller);
    const result = await caller.client.rpc("get_backoffice_sales_return_receipt_workspace");
    if (result.error) throwBackofficeReturnError(result.error);
    return Response.json(result.data);
  } catch (error) { return apiError(error); }
}
