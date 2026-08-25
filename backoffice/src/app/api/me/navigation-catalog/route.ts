import {
  apiError,
  requireActiveCompany,
  requireCaller,
} from "@/lib/server-auth";
import { buildNavigationCatalog } from "@/lib/navigation-catalog";

type PermissionResult = {
  data: unknown;
  error: { message?: string } | null;
};

function permissionCapabilities(result: PermissionResult): string[] {
  if (result.error) {
    // Navigation must fail closed per permission, not collapse the entire app
    // when client code reaches a database whose additive permission migration
    // has not been applied yet.
    if (result.error.message?.includes("PERMISSION_KEY_NOT_FOUND")) return [];
    throw result.error;
  }
  return (
    result.data as { effectiveCapabilities?: string[] } | null
  )?.effectiveCapabilities ?? [];
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request);
    const companyId = await requireActiveCompany(caller);
    const [
      profileResult,
      membershipResult,
      featureResult,
      masterPermissionResult,
      productPermissionResult,
      stockRealPermissionResult,
      stockMovementPermissionResult,
      stockTransferPermissionResult,
      customerPermissionResult,
      supplierPermissionResult,
      supplierOrderPermissionResult,
      goodsReceiptPermissionResult,
      purchaseReturnPermissionResult,
      salesDocumentPermissionResult,
      deliveryDocumentPermissionResult,
      pricelistPermissionResult,
      supplierInvoicePermissionResult,
      supplierPaymentPermissionResult,
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
      caller.client.rpc("resolve_user_permission", {
        p_company_id: companyId,
        p_target_user_id: caller.user.id,
        p_permission_key: "inventory.master_data",
      }),
      caller.client.rpc("resolve_user_permission", {
        p_company_id: companyId,
        p_target_user_id: caller.user.id,
        p_permission_key: "inventory.products",
      }),
      caller.client.rpc("resolve_user_permission", {
        p_company_id: companyId,
        p_target_user_id: caller.user.id,
        p_permission_key: "inventory.stock_real",
      }),
      caller.client.rpc("resolve_user_permission", {
        p_company_id: companyId,
        p_target_user_id: caller.user.id,
        p_permission_key: "inventory.stock_movements",
      }),
      caller.client.rpc("resolve_user_permission", {
        p_company_id: companyId,
        p_target_user_id: caller.user.id,
        p_permission_key: "inventory.stock_transfers",
      }),
      caller.client.rpc("resolve_user_permission", {
        p_company_id: companyId,
        p_target_user_id: caller.user.id,
        p_permission_key: "contacts.customers",
      }),
      caller.client.rpc("resolve_user_permission", {
        p_company_id: companyId,
        p_target_user_id: caller.user.id,
        p_permission_key: "contacts.suppliers",
      }),
      caller.client.rpc("resolve_user_permission", {
        p_company_id: companyId,
        p_target_user_id: caller.user.id,
        p_permission_key: "purchase.supplier_orders",
      }),
      caller.client.rpc("resolve_user_permission", {
        p_company_id: companyId,
        p_target_user_id: caller.user.id,
        p_permission_key: "purchase.goods_receipts",
      }),
      caller.client.rpc("resolve_user_permission", {
        p_company_id: companyId,
        p_target_user_id: caller.user.id,
        p_permission_key: "purchase.purchase_returns",
      }),
      caller.client.rpc("resolve_user_permission", {
        p_company_id: companyId,
        p_target_user_id: caller.user.id,
        p_permission_key: "sales.sales_documents",
      }),
      caller.client.rpc("resolve_user_permission", {
        p_company_id: companyId,
        p_target_user_id: caller.user.id,
        p_permission_key: "inventory.delivery_documents",
      }),
      caller.client.rpc("resolve_user_permission", {
        p_company_id: companyId,
        p_target_user_id: caller.user.id,
        p_permission_key: "sales.pricelists",
      }),
      caller.client.rpc("resolve_user_permission", {
        p_company_id: companyId,
        p_target_user_id: caller.user.id,
        p_permission_key: "finance.supplier_invoices",
      }),
      caller.client.rpc("resolve_user_permission", {
        p_company_id: companyId,
        p_target_user_id: caller.user.id,
        p_permission_key: "finance.supplier_payments",
      }),
    ]);
    if (profileResult.error) throw profileResult.error;
    if (membershipResult.error) throw membershipResult.error;
    if (featureResult.error) throw featureResult.error;
    const isSuperAdmin = profileResult.data.role === "super_admin";
    const roleCode = isSuperAdmin
      ? "SUPER_ADMIN"
      : membershipResult.data?.role_code;
    if (!roleCode) throw new Error("COMPANY_ACCESS_DENIED");

    return Response.json({
      companyId,
      roleCode,
      modules: buildNavigationCatalog({
        isSuperAdmin,
        roleCode,
        enabledFeatures: new Set(
          (featureResult.data ?? []).map((row) => row.feature_code),
        ),
        effectiveCapabilities: {
          masters: permissionCapabilities(masterPermissionResult),
          products: permissionCapabilities(productPermissionResult),
          "stock-real": permissionCapabilities(stockRealPermissionResult),
          "stock-movements": permissionCapabilities(
            stockMovementPermissionResult,
          ),
          "stock-transfers": permissionCapabilities(
            stockTransferPermissionResult,
          ),
          customers: permissionCapabilities(customerPermissionResult),
          suppliers: permissionCapabilities(supplierPermissionResult),
          "supplier-orders": permissionCapabilities(
            supplierOrderPermissionResult,
          ),
          "goods-receipts": permissionCapabilities(
            goodsReceiptPermissionResult,
          ),
          "purchase-returns": permissionCapabilities(
            purchaseReturnPermissionResult,
          ),
          "sales-documents": permissionCapabilities(
            salesDocumentPermissionResult,
          ),
          "delivery-documents": permissionCapabilities(
            deliveryDocumentPermissionResult,
          ),
          pricelists: permissionCapabilities(pricelistPermissionResult),
          "supplier-payments": permissionCapabilities(
            supplierPaymentPermissionResult,
          ),
          "supplier-invoices": permissionCapabilities(
            supplierInvoicePermissionResult,
          ),
        },
      }),
    });
  } catch (error) {
    return apiError(error);
  }
}
