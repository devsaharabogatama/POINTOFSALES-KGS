import {
  apiError,
  createAdminClient,
  requireActiveCompany,
  requireCaller,
} from "@/lib/server-auth";
import { throwBackofficeSalesOrderError } from "@/lib/backoffice-sales-order";

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request);
    const companyId = await requireActiveCompany(caller);
    const [{ data, error }, processSetting] = await Promise.all([
      caller.client.rpc("get_backoffice_sales_order_workspace"),
      createAdminClient()
        .from("company_sales_process_settings")
        .select("active_mode")
        .eq("company_id", companyId)
        .maybeSingle(),
    ]);
    if (error) throwBackofficeSalesOrderError(error);
    if (processSetting.error) throwBackofficeSalesOrderError(processSetting.error);
    const workspace = data && typeof data === "object" && !Array.isArray(data)
      ? data as Record<string, unknown>
      : {};
    return Response.json({
      ...workspace,
      activeSalesProcessMode: processSetting.data?.active_mode ?? null,
    });
  } catch (error) {
    return apiError(error);
  }
}
