import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { throwBackofficeSalesOrderError } from "@/lib/backoffice-sales-order";

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request);
    await requireActiveCompany(caller);
    const { data, error } = await caller.client.rpc("get_backoffice_sales_order_workspace");
    if (error) throwBackofficeSalesOrderError(error);
    return Response.json(data);
  } catch (error) {
    return apiError(error);
  }
}
