import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { csvDocument, importDefinitions, isImportType } from '@/lib/master-import'
import { requireImportManager, throwImportError } from '@/lib/master-import-server'

function csvResponse(content: string, fileName: string) {
  return new Response(content, {
    headers: {
      'Content-Type': 'text/csv; charset=utf-8',
      'Content-Disposition': `attachment; filename="${fileName}"`,
      'Cache-Control': 'no-store',
    },
  })
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requireImportManager(caller, companyId)
    const url = new URL(request.url)
    const importType = url.searchParams.get('type')
    const kind = url.searchParams.get('kind') ?? 'data'
    if (!isImportType(importType)) throw new ApiRouteError('UNSUPPORTED_IMPORT_TYPE', 400)
    if (!['data', 'template'].includes(kind)) throw new ApiRouteError('INVALID_EXPORT_KIND', 400)
    const definition = importDefinitions[importType]
    if (kind === 'template') {
      return csvResponse(csvDocument(definition.templateHeaders, []), `template-${importType.toLowerCase()}.csv`)
    }

    let result
    let rows: Record<string, unknown>[] = []
    if (importType === 'PRODUCT_CATEGORY') {
      result = await caller.client.from('product_categories')
        .select('id,category_name,is_active')
        .eq('company_id', companyId).order('category_name').limit(5000)
      rows = (result.data ?? []).map((row) => ({
        internal_id: row.id, name: row.category_name,
        is_active: row.is_active,
      }))
    } else if (importType === 'UOM') {
      result = await caller.client.from('uoms')
        .select('id,name,uom_type,allow_decimal,decimal_precision,is_active')
        .eq('company_id', companyId).order('name').limit(5000)
      rows = (result.data ?? []).map((row) => ({
        internal_id: row.id, name: row.name, uom_type: row.uom_type,
        allow_decimal: row.allow_decimal, decimal_precision: row.decimal_precision,
        is_active: row.is_active,
      }))
    } else if (importType === 'WAREHOUSE') {
      const [warehouseResult, storeResult] = await Promise.all([
        caller.client.from('warehouses')
          .select('id,name,warehouse_type,store_id,location,is_sale_source,is_purchase_destination,is_active')
          .eq('company_id', companyId).order('name').limit(5000),
        caller.client.from('stores').select('id,store_code,store_name')
          .eq('company_id', companyId).order('store_name').limit(5000),
      ])
      result = warehouseResult
      if (storeResult.error) throwImportError(storeResult.error)
      const storeNames = new Map((storeResult.data ?? []).map((store) => [
        store.id,
        `${store.store_name} (${store.store_code})`,
      ]))
      rows = (result.data ?? []).map((row) => ({
        internal_id: row.id, name: row.name,
        warehouse_type: row.warehouse_type,
        store_name: row.store_id ? storeNames.get(row.store_id) ?? '' : '',
        location: row.location, is_sale_source: row.is_sale_source,
        is_purchase_destination: row.is_purchase_destination, is_active: row.is_active,
      }))
    } else if (importType === 'SUPPLIER') {
      result = await caller.client.from('suppliers')
        .select('id,supplier_name,contact_name,phone,address,npwp,payment_term,bank_name,bank_account_number,bank_account_holder,is_active')
        .eq('company_id', companyId).order('supplier_name').limit(5000)
      rows = (result.data ?? []).map((row) => ({
        internal_id: row.id, name: row.supplier_name,
        contact_name: row.contact_name, phone: row.phone, address: row.address,
        npwp: row.npwp, payment_term: row.payment_term, bank_name: row.bank_name,
        bank_account_number: row.bank_account_number,
        bank_account_holder: row.bank_account_holder, is_active: row.is_active,
      }))
    } else if (importType === 'CUSTOMER_CATEGORY') {
      result = await caller.client.from('customer_categories')
        .select('id,category_name,is_active')
        .eq('company_id', companyId).order('category_name').limit(5000)
      rows = (result.data ?? []).map((row) => ({
        internal_id: row.id,
        name: row.category_name,
        is_active: row.is_active,
      }))
    } else if (importType === 'CHART_OF_ACCOUNT') {
      result = await caller.client.from('chart_of_accounts')
        .select('id,account_code,account_name,account_type,normal_balance,parent_account_id,system_function_key,is_postable,allow_manual_posting,allow_reconciliation,is_active')
        .eq('company_id', companyId).order('account_code').limit(5000)
      const accountCodes = new Map((result.data ?? []).map((row) => [
        row.id,
        row.account_code,
      ]))
      rows = (result.data ?? []).map((row) => ({
        internal_id: row.id,
        code: row.account_code,
        name: row.account_name,
        account_type: row.account_type,
        normal_balance: row.normal_balance,
        parent_account_code: row.parent_account_id
          ? accountCodes.get(row.parent_account_id) ?? ''
          : '',
        system_function_key: row.system_function_key,
        is_postable: row.is_postable,
        allow_manual_posting: row.allow_manual_posting,
        allow_reconciliation: row.allow_reconciliation,
        is_active: row.is_active,
      }))
    } else if (importType === 'TRANSACTION_CATEGORY') {
      result = await caller.client.from('transaction_categories')
        .select('id,category_name,system_key,description,is_active')
        .eq('company_id', companyId).order('category_name').limit(5000)
      rows = (result.data ?? []).map((row) => ({
        internal_id: row.id,
        name: row.category_name,
        system_key: row.system_key,
        description: row.description,
        is_active: row.is_active,
      }))
    } else if (importType === 'PRODUCT') {
      const [
        productResult,
        productUomResult,
        categoryResult,
        uomResult,
        taxRuleResult,
      ] = await Promise.all([
        caller.client.from('products')
          .select('id,sku,name,category_id,image_url,is_active,is_bundle,sales_tax_rule_id,purchase_tax_rule_id,weight_per_uom_kg')
          .eq('company_id', companyId).order('name').limit(5000),
        caller.client.from('product_uoms')
          .select('product_id,uom_id,factor_to_base,purchase_allowed,sales_allowed,purchase_price,sale_price,barcode,is_active')
          .eq('company_id', companyId).eq('is_active', true)
          .order('factor_to_base').limit(5000),
        caller.client.from('product_categories')
          .select('id,category_name').eq('company_id', companyId).limit(5000),
        caller.client.from('uoms')
          .select('id,name').eq('company_id', companyId).limit(5000),
        caller.client.from('tax_rules')
          .select('id,tax_name').eq('company_id', companyId).limit(5000),
      ])
      result = productResult
      for (const referenceResult of [
        productUomResult,
        categoryResult,
        uomResult,
        taxRuleResult,
      ]) {
        if (referenceResult.error) throwImportError(referenceResult.error)
      }
      const categoryNames = new Map((categoryResult.data ?? []).map((row) => [
        row.id,
        row.category_name,
      ]))
      const uomNames = new Map((uomResult.data ?? []).map((row) => [
        row.id,
        row.name,
      ]))
      const taxRuleNames = new Map((taxRuleResult.data ?? []).map((row) => [
        row.id,
        row.tax_name,
      ]))
      type ProductUomRow = NonNullable<typeof productUomResult.data>[number]
      const uomsByProduct = new Map<string, ProductUomRow[]>()
      for (const productUom of productUomResult.data ?? []) {
        const current = uomsByProduct.get(productUom.product_id) ?? []
        current.push(productUom)
        uomsByProduct.set(productUom.product_id, current)
      }
      rows = (productResult.data ?? []).flatMap((product) =>
        (uomsByProduct.get(product.id) ?? []).map((productUom) => ({
          internal_id: product.id,
          product_key: product.sku,
          sku: product.sku,
          product_name: product.name,
          category_name: categoryNames.get(product.category_id) ?? '',
          image_url: product.image_url,
          is_active: product.is_active,
          uom_name: uomNames.get(productUom.uom_id) ?? '',
          factor_to_base: productUom.factor_to_base,
          purchase_allowed: productUom.purchase_allowed,
          sales_allowed: productUom.sales_allowed,
          purchase_price: productUom.purchase_price,
          sale_price: productUom.sale_price,
          barcode: productUom.barcode,
          sales_tax_rule_name: product.sales_tax_rule_id
            ? taxRuleNames.get(product.sales_tax_rule_id) ?? ''
            : '',
          purchase_tax_rule_name: product.purchase_tax_rule_id
            ? taxRuleNames.get(product.purchase_tax_rule_id) ?? ''
            : '',
          weight_per_largest_uom_kg: product.weight_per_uom_kg,
        })),
      )
    } else if (importType === 'PRODUCT_SUPPLIER') {
      const [
        relationResult,
        productResult,
        supplierResult,
        uomResult,
      ] = await Promise.all([
        caller.client.from('product_suppliers')
          .select('id,product_id,supplier_id,purchase_uom_id,supplier_product_code,reference_purchase_price,is_preferred_supplier,is_active')
          .eq('company_id', companyId).order('created_at').limit(5000),
        caller.client.from('products')
          .select('id,sku').eq('company_id', companyId).limit(5000),
        caller.client.from('suppliers')
          .select('id,supplier_name').eq('company_id', companyId).limit(5000),
        caller.client.from('uoms')
          .select('id,name').eq('company_id', companyId).limit(5000),
      ])
      result = relationResult
      for (const referenceResult of [
        productResult,
        supplierResult,
        uomResult,
      ]) {
        if (referenceResult.error) throwImportError(referenceResult.error)
      }
      const productSkus = new Map((productResult.data ?? []).map((row) => [
        row.id,
        row.sku,
      ]))
      const supplierNames = new Map((supplierResult.data ?? []).map((row) => [
        row.id,
        row.supplier_name,
      ]))
      const uomNames = new Map((uomResult.data ?? []).map((row) => [
        row.id,
        row.name,
      ]))
      rows = (relationResult.data ?? []).map((relation) => ({
        internal_id: relation.id,
        product_sku: productSkus.get(relation.product_id) ?? '',
        supplier_name: supplierNames.get(relation.supplier_id) ?? '',
        purchase_uom_name: uomNames.get(relation.purchase_uom_id) ?? '',
        supplier_product_code: relation.supplier_product_code,
        reference_purchase_price: relation.reference_purchase_price,
        is_preferred_supplier: relation.is_preferred_supplier,
        is_active: relation.is_active,
      }))
    } else {
      const [settingResult, productResult, warehouseResult] = await Promise.all([
        caller.client.from('product_warehouse_stock_settings')
          .select('id,product_id,warehouse_id,minimum_stock_base_qty,low_stock_alert_enabled')
          .eq('company_id', companyId).order('updated_at').limit(5000),
        caller.client.from('products')
          .select('id,sku').eq('company_id', companyId).limit(5000),
        caller.client.from('warehouses')
          .select('id,name').eq('company_id', companyId).limit(5000),
      ])
      result = settingResult
      for (const referenceResult of [productResult, warehouseResult]) {
        if (referenceResult.error) throwImportError(referenceResult.error)
      }
      const productSkus = new Map((productResult.data ?? []).map((row) => [
        row.id,
        row.sku,
      ]))
      const warehouseNames = new Map((warehouseResult.data ?? []).map((row) => [
        row.id,
        row.name,
      ]))
      rows = (settingResult.data ?? []).map((setting) => ({
        internal_id: setting.id,
        product_sku: productSkus.get(setting.product_id) ?? '',
        warehouse_name: warehouseNames.get(setting.warehouse_id) ?? '',
        minimum_stock_base_qty: setting.minimum_stock_base_qty,
        low_stock_alert_enabled: setting.low_stock_alert_enabled,
      }))
    }
    if (result.error) throwImportError(result.error)
    return csvResponse(
      csvDocument(definition.exportHeaders, rows),
      `export-${importType.toLowerCase()}-${new Date().toISOString().slice(0, 10)}.csv`,
    )
  } catch (error) {
    return apiError(error)
  }
}
