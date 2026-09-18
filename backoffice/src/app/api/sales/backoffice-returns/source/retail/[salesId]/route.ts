import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { uuidValue } from "@/lib/master-data";
import { throwBackofficeReturnError } from "@/lib/backoffice-sales-return";

type Context = { params: Promise<{ salesId: string }> };
export async function GET(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request); await requireActiveCompany(caller);
    const { salesId } = await params;
    const result = await caller.client.rpc("get_retained_retail_backoffice_return_source", {
      p_sales_id: uuidValue(salesId, "RETAINED_RETAIL_SALES_ID_INVALID"),
    });
    if (result.error) throwBackofficeReturnError(result.error);
    return Response.json(result.data);
  } catch (error) { return apiError(error); }
}
