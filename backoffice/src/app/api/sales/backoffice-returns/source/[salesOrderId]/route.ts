import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { uuidValue } from "@/lib/master-data";
import { throwBackofficeReturnError } from "@/lib/backoffice-sales-return";

type Context = { params: Promise<{ salesOrderId: string }> };
export async function GET(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request); await requireActiveCompany(caller);
    const { salesOrderId } = await params;
    const result = await caller.client.rpc("get_backoffice_sales_return_source", {
      p_sales_order_id: uuidValue(salesOrderId, "BACKOFFICE_SALES_ORDER_ID_INVALID"),
    });
    if (result.error) throwBackofficeReturnError(result.error);
    return Response.json(result.data);
  } catch (error) { return apiError(error); }
}
