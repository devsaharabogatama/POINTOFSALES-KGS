import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { csvDocument, importDefinitions, isImportType } from '@/lib/master-import'
import { requireImportManager, throwImportError } from '@/lib/master-import-server'
import { requireDataExchangeAction } from '@/lib/data-exchange-server'

function csvResponse(content: string, fileName: string) {
  return new Response(content, {
    headers: {
      'Content-Type': 'text/csv; charset=utf-8',
      'Content-Disposition': `attachment; filename="${fileName}"`,
      'Cache-Control': 'no-store',
    },
  })
}

type ProductUomExchangeRow = {
  row_mode: 'REFERENCE' | 'INPUT'
  product_sku: string
  product_name: string
  uom_name: string | null
  factor_to_base: number | string | null
  purchase_allowed: boolean | null
  sales_allowed: boolean | null
  purchase_price: number | string | null
  sale_price: number | string | null
  barcode: string | null
  weight_if_largest_kg: number | string | null
}

function productUomCsvRows(data: unknown) {
  return ((data ?? []) as ProductUomExchangeRow[]).map((row) => ({
    row_mode: row.row_mode,
    product_sku: row.product_sku,
    product_name: row.product_name,
    uom_name: row.uom_name ?? '',
    factor_to_base: row.factor_to_base ?? '',
    purchase_allowed: row.purchase_allowed ?? '',
    sales_allowed: row.sales_allowed ?? '',
    purchase_price: row.purchase_price ?? '',
    sale_price: row.sale_price ?? '',
    barcode: row.barcode ?? '',
    weight_if_largest_kg: row.weight_if_largest_kg ?? '',
  }))
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const url = new URL(request.url)
    const importType = url.searchParams.get('type')
    const kind = url.searchParams.get('kind') ?? 'data'
    if (!isImportType(importType)) throw new ApiRouteError('UNSUPPORTED_IMPORT_TYPE', 400)
    if (!['data', 'template'].includes(kind)) throw new ApiRouteError('INVALID_EXPORT_KIND', 400)
    if (kind === 'data') {
      await requireDataExchangeAction(caller, companyId, importType, 'EXPORT')
    } else {
      await requireImportManager(caller, companyId)
      if (importType === 'PRODUCT' ||
          importType === 'PRODUCT_UOM' ||
          importType === 'PRODUCT_WAREHOUSE_MINIMUM_STOCK' ||
          importType === 'CUSTOMER' ||
          importType === 'CUSTOMER_CATEGORY' ||
          importType === 'SUPPLIER' ||
          importType === 'PRODUCT_SUPPLIER') {
        await requireDataExchangeAction(caller, companyId, importType, 'IMPORT')
      }
    }
    const definition = importDefinitions[importType]
    if (kind === 'template') {
      if (importType === 'PRODUCT_UOM') {
        const templateResult = await caller.client.rpc('get_inventory_product_uom_import_template')
        if (templateResult.error) throwImportError(templateResult.error)
        return csvResponse(
          csvDocument(definition.templateHeaders, productUomCsvRows(templateResult.data)),
          `template-${importType.toLowerCase()}.csv`,
        )
      }
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
      result = await caller.client.rpc('export_contacts_suppliers')
      const supplierRows = (result.data ?? []) as Array<{
        id: string; supplier_name: string; contact_name: string | null
        phone: string | null; address: string | null; npwp: string | null
        payment_term: string | null; bank_name: string | null
        bank_account_number: string | null; bank_account_holder: string | null
        is_active: boolean
      }>
      rows = supplierRows.map((row) => ({
        internal_id: row.id, name: row.supplier_name,
        contact_name: row.contact_name, phone: row.phone, address: row.address,
        npwp: row.npwp, payment_term: row.payment_term, bank_name: row.bank_name,
        bank_account_number: row.bank_account_number,
        bank_account_holder: row.bank_account_holder, is_active: row.is_active,
      }))
    } else if (importType === 'CUSTOMER') {
      result = await caller.client.rpc('export_contacts_customers')
      rows = ((result.data ?? []) as Array<{
        id: string; customer_code: string; customer_name: string
        customer_category_name: string; parent_customer_name: string | null
        default_pricelist_name: string | null; phone: string | null
        email: string | null; address: string | null; customer_type: string
        credit_limit: number | string; credit_term_days: number | null
        notes: string | null; is_active: boolean
      }>).map((row) => ({
        internal_id: row.id,
        code: row.customer_code,
        name: row.customer_name,
        customer_category_name: row.customer_category_name,
        parent_customer_name: row.parent_customer_name,
        default_pricelist_name: row.default_pricelist_name,
        phone: row.phone,
        email: row.email,
        address: row.address,
        customer_type: row.customer_type,
        credit_limit: row.credit_limit,
        credit_term_days: row.credit_term_days,
        notes: row.notes,
        is_active: row.is_active,
      }))
    } else if (importType === 'CUSTOMER_CATEGORY') {
      result = await caller.client.rpc('export_contacts_customer_categories')
      rows = ((result.data ?? []) as Array<{
        id: string; category_name: string; is_active: boolean
      }>).map((row) => ({
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
    } else if (importType === 'PRODUCT_UOM') {
      result = await caller.client.rpc('export_inventory_product_uom_placeholders')
      rows = productUomCsvRows(result.data)
    } else if (importType === 'PRODUCT_SUPPLIER') {
      result = await caller.client.rpc('export_contacts_product_suppliers')
      const relationRows = (result.data ?? []) as Array<{
        id: string; product_sku: string; supplier_name: string
        purchase_uom_name: string; supplier_product_code: string | null
        reference_purchase_price: number | string | null
        is_preferred_supplier: boolean; is_active: boolean
      }>
      rows = relationRows.map((relation) => ({
        internal_id: relation.id,
        product_sku: relation.product_sku,
        supplier_name: relation.supplier_name,
        purchase_uom_name: relation.purchase_uom_name,
        supplier_product_code: relation.supplier_product_code,
        reference_purchase_price: relation.reference_purchase_price,
        is_preferred_supplier: relation.is_preferred_supplier,
        is_active: relation.is_active,
      }))
    } else {
      result = await caller.client.rpc('get_inventory_minimum_stock')
      if (result.error) throwImportError(result.error)
      const payload = (result.data ?? {}) as {
        data?: Array<{
          id: string
          product_id: string
          warehouse_id: string
          minimum_stock_base_qty: number | string | null
          low_stock_alert_enabled: boolean
        }>
        products?: Array<{ id: string; sku: string }>
        warehouses?: Array<{ id: string; name: string }>
      }
      const productSkus = new Map((payload.products ?? []).map((row) => [
        row.id,
        row.sku,
      ]))
      const warehouseNames = new Map((payload.warehouses ?? []).map((row) => [
        row.id,
        row.name,
      ]))
      rows = (payload.data ?? []).map((setting) => ({
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
