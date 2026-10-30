import { expect, test, type Page, type Route } from '@playwright/test'

const IDS = {
  user: '10000000-0000-4000-8000-000000000001',
  company: 'a59c534b-909f-4b3f-aba0-ae9db6d90b76',
  store: '4a71e3ce-11a6-4007-97a3-851e17308b33',
  terminal: 'ee95fb7c-9a6e-4227-b134-0e79e63432b1',
  warehouse: '7c5739e6-f291-4aa2-a1e4-56e1a230aad9',
  session: '20000000-0000-4000-8000-000000000001',
  product: '30000000-0000-4000-8000-000000000001',
  productUom: '30000000-0000-4000-8000-000000000002',
  uom: '30000000-0000-4000-8000-000000000003',
  category: '30000000-0000-4000-8000-000000000004',
  customer: '40000000-0000-4000-8000-000000000001',
  pricelist: '50000000-0000-4000-8000-000000000001',
  payment: '60000000-0000-4000-8000-000000000001',
  sale: '70000000-0000-4000-8000-000000000001',
}

const jsonHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': '*',
  'content-type': 'application/json',
}

const pwaBaseUrl = process.env.PWA_QA_URL ?? 'http://127.0.0.1:5197'

async function reply(route: Route, body: unknown, status = 200) {
  await route.fulfill({ status, headers: jsonHeaders, body: JSON.stringify(body) })
}

async function installRetailServerMock(page: Page) {
  const rpcCalls: string[] = []
  await page.route('https://*.supabase.co/**', async (route) => {
    const request = route.request()
    const url = new URL(request.url())
    const path = url.pathname

    if (path === '/auth/v1/token') {
      const now = new Date().toISOString()
      return reply(route, {
        access_token: 'qa-access-token',
        token_type: 'bearer',
        expires_in: 3600,
        expires_at: Math.floor(Date.now() / 1000) + 3600,
        refresh_token: 'qa-refresh-token',
        user: {
          id: IDS.user,
          aud: 'authenticated',
          role: 'authenticated',
          email: 'qa.cashier@example.test',
          app_metadata: { provider: 'email', providers: ['email'] },
          user_metadata: {},
          identities: [],
          created_at: now,
          updated_at: now,
        },
      })
    }
    if (path === '/auth/v1/user') {
      return reply(route, {
        id: IDS.user,
        aud: 'authenticated',
        role: 'authenticated',
        email: 'qa.cashier@example.test',
        app_metadata: { provider: 'email', providers: ['email'] },
        user_metadata: {},
        identities: [],
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      })
    }

    if (path.startsWith('/rest/v1/rpc/')) {
      const rpc = path.split('/').at(-1) ?? ''
      rpcCalls.push(rpc)
      const responses: Record<string, unknown> = {
        get_company_branding: { deliveryDocumentCreationPolicy: 'DELIVERY_ONLY' },
        get_pos_stock_availability: {
          reservationReadModelVersion: 1,
          availability: [{ stock_product_id: IDS.product, available_to_sell_base_qty: 120 }],
        },
        get_pos_customer_references: [{
          id: IDS.customer, code: 'WALK-IN', name: 'Customer Umum KGFF', phone: null,
          address: null, is_system_customer: true, default_pricelist_id: IDS.pricelist,
          current_balance: 0, credit_limit: 0, credit_term_days: null,
        }],
        get_pos_pricelist_references: [{
          id: IDS.pricelist, name: 'Harga Retail KGFF', scope: 'GLOBAL', is_default: true,
          applies_all_stores: true, valid_from: null, valid_until: null,
        }],
        get_pos_payment_method_references: [{
          id: IDS.payment, payment_method_name: 'Cash', method_type: 'CASH',
          proof_mode: 'NONE', is_default: true, fee_bearer: null, fee_enabled: false,
          fee_type: null, fee_percent: 0, fee_fixed_amount: 0,
        }],
        get_pos_expense_categories: { categories: [] },
        list_pos_sale_drafts: [],
        get_pos_sales_orders: { orders: [], reservationLines: [] },
        get_pos_sales_order_revision_eligibility: [],
        preview_pos_sale_prices: {
          lines: [{
            lineKey: IDS.productUom, productUomId: IDS.productUom,
            productName: 'Ayam Frozen QA', productSku: 'QA-AYAM', uomName: 'PACK',
            quantity: 1, baseUnitPrice: 25000, unitPrice: 25000,
            pricelistId: IDS.pricelist, pricelistRuleId: null,
            pricelistName: 'Harga Retail KGFF', pricingSelectionSource: 'AUTO',
          }],
        },
        save_pos_sale_draft_with_pricelist: {
          salesId: IDS.sale, draftNo: 'DRF-QA-0001', masterVersion: 1,
          grandTotalBeforeRounding: 25000, roundingAdjustment: 0,
          grandTotalAfterRounding: 25000, deliveryFeeAmount: 0,
          deliveryFeeInvoiceDisplayMode: 'SHOW_SEPARATE',
        },
        post_pos_sale_with_pricelist: {
          salesId: IDS.sale, documentStatus: 'POSTED', masterVersion: 2,
        },
        get_pos_sales_invoice_document: {
          invoiceSnapshotId: '80000000-0000-4000-8000-000000000001',
          invoiceNo: 'INV-QA-0001', invoiceDate: '2026-10-30', snapshotVersion: 1,
          snapshotProvenance: 'LIVE_POST', snapshot: {},
        },
        get_pos_sales_delivery_document: null,
        get_pos_negative_stock_readiness: {
          enabled: false, blockerCode: 'FEATURE_DISABLED', onlineOnly: true,
          bundleSupported: false, requireReason: false, warehouseId: IDS.warehouse,
        },
      }
      return reply(route, responses[rpc] ?? {})
    }

    const table = path.replace('/rest/v1/', '')
    const objectResponse = request.headers()['accept']?.includes('vnd.pgrst.object')
    const rows: Record<string, unknown> = {
      profiles: { role: 'super_admin' },
      user_active_company_contexts: { company_id: IDS.company },
      companies: [{ id: IDS.company, company_name: 'Kidul Gunung Frozen Food' }],
      store_memberships: [],
      stores: [{ id: IDS.store, store_name: 'Toko Utama' }],
      pos_terminals: [{
        id: IDS.terminal, store_id: IDS.store, pos_code: 'POS-1',
        pos_name: 'Kasir Utama POS-1', hidden_feature_keys: [], allow_price_override: false,
      }],
      warehouses: [{ id: IDS.warehouse, store_id: IDS.store, name: 'Gudang Toko' }],
      cashier_sessions: {
        id: IDS.session, session_code: 'SES-QA-KGFF', pos_id: IDS.terminal,
        sales_warehouse_id: IDS.warehouse, store_id: IDS.store,
        opening_cash_actual: 100000, expected_cash: 100000, master_version: 1,
      },
      products: [{ id: IDS.product, sku: 'QA-AYAM', name: 'Ayam Frozen QA', category_id: IDS.category, is_bundle: false }],
      product_uoms: [{
        id: IDS.productUom, product_id: IDS.product, uom_id: IDS.uom,
        factor_to_base: 1, sale_price: 25000, barcode: 'QA001',
        is_active: true, sales_allowed: true,
      }],
      uoms: [{ id: IDS.uom, name: 'PACK', allow_decimal: false, decimal_precision: 0 }],
      product_categories: [{ id: IDS.category, category_name: 'Frozen Food' }],
      company_features: { is_enabled: true },
      sales_details: [],
      sales_headers: objectResponse ? {
        receipt_snapshot: {
          saleId: IDS.sale, invoiceNo: 'INV-QA-0001', postedAt: '2026-10-30T04:00:00.000Z',
          subtotal: 25000, itemDiscount: 0, orderDiscount: 0,
          totalBeforeRounding: 25000, roundingAdjustment: 0, grandTotal: 25000,
          deliveryFeeAmount: 0, customerSurcharge: 0, amountPaid: 25000,
          lines: [{
            productName: 'Ayam Frozen QA', sku: 'QA-AYAM', uomName: 'PACK',
            quantity: 1, unitPrice: 25000, discount: 0, taxAmount: 0, lineTotal: 25000,
          }],
          payments: [{
            paymentMethodName: 'Cash', amount: 25000, configuredFee: 0,
            customerSurcharge: 0, tenderedAmount: 25000, changeAmount: 0,
          }],
        },
      } : [],
      sales_payments: [],
    }
    const response = rows[table]
    if (response !== undefined) return reply(route, response)
    return reply(route, objectResponse ? null : [])
  })
  return rpcCalls
}

test('posts KGFF Pickup directly as Retail with receipt and Invoice but without Order reservation or Surat Jalan', async ({ page }) => {
  const rpcCalls = await installRetailServerMock(page)
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('not-a-real-password')
  await page.getByRole('button', { name: 'Masuk' }).click()

  await expect(page.getByText('Kidul Gunung Frozen Food')).toBeVisible()
  await expect(page.getByText('SES-QA-KGFF')).toBeVisible()
  await expect(page.getByRole('button', { name: /Ayam Frozen QA/ })).toBeVisible()
  await expect(page.getByLabel('Customer', { exact: true })).toHaveValue(IDS.customer)
  await expect(page.getByLabel('Pricelist')).toContainText('Harga Retail KGFF')

  await page.getByRole('button', { name: /Ayam Frozen QA/ }).click()
  await page.getByRole('button', { name: 'Atur pembayaran' }).click()
  const paymentDialog = page.getByRole('dialog', { name: 'Pembayaran dan penyelesaian' })
  await expect(paymentDialog.getByText('Pembayaran & penyelesaian')).toBeVisible()
  await expect(paymentDialog.getByText('Rp 25.000', { exact: true }).first()).toBeVisible()
  await page.getByRole('button', { name: 'Simpan Draft' }).click()
  await expect(page.getByText(/Draft tersimpan/)).toBeVisible()
  await page.getByRole('button', { name: 'Selesaikan Transaksi' }).click()
  await expect(page.getByText('Transaksi Posted')).toBeVisible()
  await expect(page.getByText('INV-QA-0001')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Invoice A4' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Surat Jalan' })).toHaveCount(0)

  for (const required of [
    'get_company_branding',
    'get_pos_stock_availability',
    'get_pos_customer_references',
    'get_pos_pricelist_references',
    'get_pos_payment_method_references',
    'preview_pos_sale_prices',
    'save_pos_sale_draft_with_pricelist',
    'post_pos_sale_with_pricelist',
    'get_pos_sales_invoice_document',
  ]) expect(rpcCalls, `Retail flow must call ${required}`).toContain(required)
  expect(rpcCalls, 'Pickup Retail must not enter the Order/reservation runtime').not.toContain('confirm_pos_sales_order')
  expect(rpcCalls, 'Pickup Retail must not create or load a Surat Jalan').not.toContain('get_pos_sales_delivery_document')
})
