import {
  apiError,
  requireActiveCompany,
  requireCaller,
} from "@/lib/server-auth";
import {
  buildNavigationCatalog,
  NAVIGATION_PERMISSION_KEYS,
} from "@/lib/navigation-catalog";
import type { NavigationViewId } from "@/lib/navigation-catalog";
import { getFinanceProcessUiPolicy } from "@/lib/finance-process-ui-policy";

type PermissionResult = {
  data: unknown;
  error: { message?: string } | null;
};

type PermissionProfileItem = {
  permissionKey?: string;
  effectiveCapabilities?: string[];
};

function permissionProfile(result: PermissionResult): PermissionProfileItem[] {
  if (result.error) {
    throw result.error;
  }
  const items = (result.data as { items?: unknown } | null)?.items;
  return Array.isArray(items) ? (items as PermissionProfileItem[]) : [];
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request);
    const companyId = await requireActiveCompany(caller);
    const [
      profileResult,
      membershipResult,
      featureResult,
      permissionProfileResult,
      financeProcessUiPolicy,
    ] = await Promise.all([
      caller.client
        .from("profiles")
        .select("role")
        .eq("id", caller.user.id)
        .single(),
      caller.client
        .from("company_memberships")
        .select("role_code,status")
        .eq("company_id", companyId)
        .eq("user_id", caller.user.id)
        .eq("status", "ACTIVE")
        .maybeSingle(),
      caller.client
        .from("company_features")
        .select("feature_code")
        .eq("company_id", companyId)
        .eq("is_enabled", true),
      caller.client.rpc("list_user_permission_profile", {
        p_company_id: companyId,
        p_target_user_id: caller.user.id,
      }),
      getFinanceProcessUiPolicy(companyId),
    ]);
    if (profileResult.error) throw profileResult.error;
    if (membershipResult.error) throw membershipResult.error;
    if (featureResult.error) throw featureResult.error;
    const isSuperAdmin = profileResult.data.role === "super_admin";
    const roleCode = isSuperAdmin
      ? "SUPER_ADMIN"
      : membershipResult.data?.role_code;
    if (!roleCode) throw new Error("COMPANY_ACCESS_DENIED");

    const capabilitiesByPermissionKey = new Map(
      permissionProfile(permissionProfileResult)
        .filter((item) => typeof item.permissionKey === "string")
        .map((item) => [
          item.permissionKey as string,
          Array.isArray(item.effectiveCapabilities)
            ? item.effectiveCapabilities
            : [],
        ]),
    );
    const effectiveCapabilities = Object.fromEntries(
      (Object.entries(NAVIGATION_PERMISSION_KEYS) as [NavigationViewId, string][])
        .map(([viewId, permissionKey]) => [
          viewId,
          capabilitiesByPermissionKey.get(permissionKey) ?? [],
        ]),
    ) as Partial<Record<NavigationViewId, string[]>>;

    const hiddenViewIds = new Set<NavigationViewId>();
    if (!financeProcessUiPolicy.showRetailCashDeposits) {
      hiddenViewIds.add("cash-deposits");
    }
    if (!financeProcessUiPolicy.showRetailDepositVariances) {
      hiddenViewIds.add("deposit-variances");
    }

    return Response.json({
      companyId,
      roleCode,
      financeProcessUiPolicy,
      modules: buildNavigationCatalog({
        isSuperAdmin,
        roleCode,
        hiddenViewIds,
        enabledFeatures: new Set(
          (featureResult.data ?? []).map((row) => row.feature_code),
        ),
        effectiveCapabilities,
      }),
    });
  } catch (error) {
    return apiError(error);
  }
}
