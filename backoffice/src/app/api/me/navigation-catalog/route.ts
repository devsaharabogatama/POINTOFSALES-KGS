import {
  apiError,
  requireActiveCompany,
  requireCaller,
} from "@/lib/server-auth";
import { buildNavigationCatalog } from "@/lib/navigation-catalog";

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
    if (masterPermissionResult.error) throw masterPermissionResult.error;
    if (productPermissionResult.error) throw productPermissionResult.error;
    if (stockRealPermissionResult.error) throw stockRealPermissionResult.error;
    if (stockMovementPermissionResult.error)
      throw stockMovementPermissionResult.error;
    if (stockTransferPermissionResult.error)
      throw stockTransferPermissionResult.error;
    if (customerPermissionResult.error) throw customerPermissionResult.error;
    if (supplierPermissionResult.error) throw supplierPermissionResult.error;
    if (supplierOrderPermissionResult.error)
      throw supplierOrderPermissionResult.error;
    if (purchaseReturnPermissionResult.error)
      throw purchaseReturnPermissionResult.error;
    if (salesDocumentPermissionResult.error)
      throw salesDocumentPermissionResult.error;
    if (deliveryDocumentPermissionResult.error)
      throw deliveryDocumentPermissionResult.error;
    if (pricelistPermissionResult.error)
      throw pricelistPermissionResult.error;
    if (supplierPaymentPermissionResult.error)
      throw supplierPaymentPermissionResult.error;
    if (supplierInvoicePermissionResult.error)
      throw supplierInvoicePermissionResult.error;

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
          masters:
            (
              masterPermissionResult.data as {
                effectiveCapabilities?: string[];
              }
            )?.effectiveCapabilities ?? [],
          products:
            (
              productPermissionResult.data as {
                effectiveCapabilities?: string[];
              }
            )?.effectiveCapabilities ?? [],
          "stock-real":
            (
              stockRealPermissionResult.data as {
                effectiveCapabilities?: string[];
              }
            )?.effectiveCapabilities ?? [],
          "stock-movements":
            (
              stockMovementPermissionResult.data as {
                effectiveCapabilities?: string[];
              }
            )?.effectiveCapabilities ?? [],
          "stock-transfers":
            (
              stockTransferPermissionResult.data as {
                effectiveCapabilities?: string[];
              }
            )?.effectiveCapabilities ?? [],
          customers:
            (
              customerPermissionResult.data as {
                effectiveCapabilities?: string[];
              }
            )?.effectiveCapabilities ?? [],
          suppliers:
            (
              supplierPermissionResult.data as {
                effectiveCapabilities?: string[];
              }
            )?.effectiveCapabilities ?? [],
          "supplier-orders":
            (
              supplierOrderPermissionResult.data as {
                effectiveCapabilities?: string[];
              }
            )?.effectiveCapabilities ?? [],
          "purchase-returns":
            (
              purchaseReturnPermissionResult.data as {
                effectiveCapabilities?: string[];
              }
            )?.effectiveCapabilities ?? [],
          "sales-documents":
            (
              salesDocumentPermissionResult.data as {
                effectiveCapabilities?: string[];
              }
            )?.effectiveCapabilities ?? [],
          "delivery-documents":
            (
              deliveryDocumentPermissionResult.data as {
                effectiveCapabilities?: string[];
              }
            )?.effectiveCapabilities ?? [],
          pricelists:
            (
              pricelistPermissionResult.data as {
                effectiveCapabilities?: string[];
              }
            )?.effectiveCapabilities ?? [],
          "supplier-payments":
            (
              supplierPaymentPermissionResult.data as {
                effectiveCapabilities?: string[];
              }
            )?.effectiveCapabilities ?? [],
          "supplier-invoices":
            (
              supplierInvoicePermissionResult.data as {
                effectiveCapabilities?: string[];
              }
            )?.effectiveCapabilities ?? [],
        },
      }),
    });
  } catch (error) {
    return apiError(error);
  }
}
