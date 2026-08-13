import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { authorizedDataExchangeCatalog } from "@/lib/data-exchange-server";

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request);
    const companyId = await requireActiveCompany(caller);
    const items = await authorizedDataExchangeCatalog(caller, companyId);
    return Response.json(
      { data: { companyId, items } },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return apiError(error);
  }
}
