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
  expenseCategory: '30000000-0000-4000-8000-000000000008',
  ketulProduct: '30000000-0000-4000-8000-000000000005',
  ketulProductUom: '30000000-0000-4000-8000-000000000006',
  ketulCategory: '30000000-0000-4000-8000-000000000007',
  lettuceProduct: '30000000-0000-4000-8000-000000000010',
  lettuceProductUom: '30000000-0000-4000-8000-000000000011',
  bombayProduct: '30000000-0000-4000-8000-000000000012',
  bombayProductUom: '30000000-0000-4000-8000-000000000013',
  customer: '40000000-0000-4000-8000-000000000001',
  namedCustomer: '40000000-0000-4000-8000-000000000002',
  pricelist: '50000000-0000-4000-8000-000000000001',
  payment: '60000000-0000-4000-8000-000000000001',
  qrisPayment: '60000000-0000-4000-8000-000000000002',
  transferPayment: '60000000-0000-4000-8000-000000000003',
  sale: '70000000-0000-4000-8000-000000000001',
  supplier: '80000000-0000-4000-8000-000000000001',
  supplierOrder: '80000000-0000-4000-8000-000000000002',
  supplierOrderLine: '80000000-0000-4000-8000-000000000003',
  goodsReceipt: '80000000-0000-4000-8000-000000000004',
  receiptLine: '80000000-0000-4000-8000-000000000005',
  receiptAllocation: '80000000-0000-4000-8000-000000000006',
  productBatch: '80000000-0000-4000-8000-000000000007',
  stockOpname: '80000000-0000-4000-8000-000000000008',
  stockOpnameDetail: '80000000-0000-4000-8000-000000000009',
  closedSession: '80000000-0000-4000-8000-000000000010',
  cashDeposit: '80000000-0000-4000-8000-000000000011',
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

async function installRetailServerMock(
  page: Page,
  options: {
    ketulReady?: boolean
    sessionOpen?: boolean
    zeroPriceForNamedCustomer?: boolean
    zeroPriceDiscountDraft?: boolean
    allowPriceOverride?: boolean
  } = {},
) {
  const rpcCalls: Array<{ name: string; payload: unknown }> = []
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
      const payload = request.postDataJSON()
      rpcCalls.push({ name: rpc, payload })
      const responses: Record<string, unknown> = {
        get_company_branding: { deliveryDocumentCreationPolicy: 'DELIVERY_ONLY' },
        get_pos_stock_availability: {
          reservationReadModelVersion: 1,
          availability: [
            { stock_product_id: IDS.product, available_to_sell_base_qty: 120 },
            { stock_product_id: IDS.ketulProduct, available_to_sell_base_qty: 0 },
            { stock_product_id: IDS.lettuceProduct, available_to_sell_base_qty: 120 },
            { stock_product_id: IDS.bombayProduct, available_to_sell_base_qty: 120 },
          ],
        },
        get_pos_customer_references: [
          {
            id: IDS.customer, code: 'WALK-IN', name: 'Customer Umum KGFF', phone: null,
            address: null, is_system_customer: true, default_pricelist_id: IDS.pricelist,
            current_balance: 0, credit_limit: 0, credit_term_days: null,
          },
          {
            id: IDS.namedCustomer, code: 'CUST-QA', name: 'Customer QA Named', phone: null,
            address: null, is_system_customer: false, default_pricelist_id: IDS.pricelist,
            current_balance: 0, credit_limit: 0, credit_term_days: null,
          },
        ],
        get_pos_pricelist_references: [{
          id: IDS.pricelist, name: 'Harga Retail KGFF', scope: 'GLOBAL', is_default: true,
          applies_all_stores: true, valid_from: null, valid_until: null,
        }],
        get_pos_payment_method_references: [
          {
            id: IDS.payment, payment_method_name: 'Cash', method_type: 'CASH',
            proof_mode: 'NONE', is_default: true, fee_bearer: null, fee_enabled: false,
            fee_type: null, fee_percent: 0, fee_fixed_amount: 0,
          },
          {
            id: IDS.qrisPayment, payment_method_name: 'QRIS', method_type: 'QRIS',
            proof_mode: 'NONE', is_default: false, fee_bearer: null, fee_enabled: false,
            fee_type: null, fee_percent: 0, fee_fixed_amount: 0,
          },
          {
            id: IDS.transferPayment, payment_method_name: 'Transfer Bank',
            method_type: 'TRANSFER', proof_mode: 'OPTIONAL', is_default: false,
            fee_bearer: null, fee_enabled: false, fee_type: null,
            fee_percent: 0, fee_fixed_amount: 0,
          },
          {
            id: '60000000-0000-4000-8000-000000000004',
            payment_method_name: 'Potongan Ketul', method_type: 'KETUL_OFFSET',
            proof_mode: 'OPTIONAL', is_default: false, fee_bearer: null,
            fee_enabled: false, fee_type: null, fee_percent: 0,
            fee_fixed_amount: 0,
          },
        ],
        get_pos_expense_categories: { categories: [{
          id: IDS.expenseCategory, category_name: 'Biaya Operasional',
          evidence_policy: 'OPTIONAL', default_payment_method_id: IDS.payment,
        }] },
        get_pos_ketul_readiness: {
          enabled: true, ready: options.ketulReady ?? true,
          blockerCode: (options.ketulReady ?? true)
            ? null
            : 'KETUL_PAYABLE_MAPPING_NOT_READY',
          onlineOnly: true, productCount: 1,
        },
        quick_create_pos_customer: {
          customerId: '40000000-0000-4000-8000-000000000099',
          customerName: 'Customer Baru QA', companyId: IDS.company,
        },
        get_pos_expense_workspace: {
          approvedCashExpenses: [], outstandingExpenses: [],
          approvedAdditionalCashExpenses: [],
          sessionExpenseSummary: {
            documentCount: 2, totalAmount: 40000,
            cashAmount: 30000, nonCashAmount: 10000,
          },
        },
        get_pos_cashier_session_return_adjustments: {
          companyId: IDS.company,
          cashierSessionId: IDS.session,
          processMode: 'RETAIL_CONFIRM_INVOICE',
          applicable: true,
          refunds: [
            {
              key: '73000000-0000-4000-8000-000000000001',
              documentId: '74000000-0000-4000-8000-000000000001',
              returnNo: 'RTN-QA-CASH', sourceSalesId: IDS.sale,
              paymentMethodId: IDS.payment, paymentMethodName: 'Cash',
              paymentMethodType: 'CASH', settlementRoute: 'CASH_DRAWER',
              amount: 5000,
            },
            {
              key: '73000000-0000-4000-8000-000000000002',
              documentId: '74000000-0000-4000-8000-000000000002',
              returnNo: 'RTN-QA-QRIS', sourceSalesId: IDS.sale,
              paymentMethodId: IDS.qrisPayment, paymentMethodName: 'QRIS',
              paymentMethodType: 'QRIS', settlementRoute: 'PAYMENT_CLEARING',
              amount: 1000,
            },
          ],
          lines: [
            {
              key: '75000000-0000-4000-8000-000000000001',
              documentId: '74000000-0000-4000-8000-000000000001',
              returnNo: 'RTN-QA-CASH', sourceSalesId: IDS.sale,
              productId: IDS.product, productName: 'Ayam Frozen QA',
              productSku: 'QA-AYAM', uomName: 'PACK', quantity: 0.25,
              returnCondition: 'SALEABLE',
            },
            {
              key: '75000000-0000-4000-8000-000000000002',
              documentId: '74000000-0000-4000-8000-000000000002',
              returnNo: 'RTN-QA-QRIS', sourceSalesId: IDS.sale,
              productId: IDS.product, productName: 'Ayam Frozen QA',
              productSku: 'QA-AYAM', uomName: 'PACK', quantity: 0.5,
              returnCondition: 'NO_PHYSICAL_RETURN',
            },
          ],
        },
        get_pos_stock_request_workspace: {
          options: [{
            product_id: IDS.product, uom_id: IDS.uom, sku: 'QA-AYAM',
            product_name: 'Ayam Frozen QA', uom_name: 'PACK', factor_to_base: 1,
            allow_decimal: false, decimal_precision: 0,
          }],
          documents: [],
        },
        save_stock_request: {
          documentId: '81000000-0000-4000-8000-000000000001',
          requestNo: 'REQ-QA-0001', masterVersion: 1,
        },
        submit_stock_request: {
          documentId: '81000000-0000-4000-8000-000000000001',
          requestNo: 'REQ-QA-0001', status: 'SUBMITTED',
        },
        get_pos_goods_receipt_supplier_orders: {
          orders: [{
            id: IDS.supplierOrder, order_no: 'PO-QA-0001',
            supplier_id: IDS.supplier, supplier_name: 'Supplier QA',
            destination_warehouse_id: IDS.warehouse, warehouse_name: 'Gudang Toko',
            status: 'ORDERED', expected_date: '2026-11-01',
          }],
          lines: [{
            id: IDS.supplierOrderLine, document_id: IDS.supplierOrder,
            product_id: IDS.product, ordered_uom_id: IDS.uom,
            ordered_qty: 10, ordered_base_qty: 10,
            product_name_snapshot: 'Ayam Frozen QA',
            ordered_uom_name_snapshot: 'PACK',
          }],
        },
        save_goods_receipt: {
          documentId: IDS.goodsReceipt, receiptNo: 'GR-QA-0001',
          status: 'DRAFT', masterVersion: 1,
        },
        post_goods_receipt: {
          documentId: IDS.goodsReceipt, receiptNo: 'GR-QA-0001',
          status: 'POSTED', masterVersion: 2, idempotentReplay: false,
        },
        get_pos_purchase_return_workspace: {
          receipts: [{
            id: IDS.goodsReceipt, receipt_no: 'GR-QA-0001',
            supplier_order_id: IDS.supplierOrder,
            received_at: '2026-11-01T08:00:00.000Z',
          }],
          drafts: [],
          receiptLines: [{
            id: IDS.receiptLine, document_id: IDS.goodsReceipt,
            product_id: IDS.product, product_name_snapshot: 'Ayam Frozen QA',
            base_uom_name_snapshot: 'PACK',
          }],
          allocations: [{
            id: IDS.receiptAllocation, receipt_line_id: IDS.receiptLine,
            condition_type: 'GOOD', warehouse_id: IDS.warehouse,
            quantity_base: 10, product_batch_id: IDS.productBatch,
          }],
          batches: [{ id: IDS.productBatch, qty_remaining: 10 }],
          returnLines: [],
          productUoms: [{
            product_id: IDS.product, uom_id: IDS.uom, factor_to_base: 1,
            uom_name: 'PACK', allow_decimal: false, decimal_precision: 0,
          }],
          orders: [{
            id: IDS.supplierOrder, order_no: 'PO-QA-0001', supplier_id: IDS.supplier,
          }],
          suppliers: [{ id: IDS.supplier, supplier_name: 'Supplier QA' }],
          warehouses: [{ id: IDS.warehouse, name: 'Gudang Toko' }],
        },
        save_purchase_return_draft: {
          documentId: '81000000-0000-4000-8000-000000000002',
          returnNo: 'PR-QA-0001', status: 'DRAFT', reviewStatus: 'PENDING',
          masterVersion: 1,
        },
        get_pos_stock_opname_workspace: {
          warehouses: [{ id: IDS.warehouse, name: 'Gudang Toko', storeId: IDS.store }],
          categories: [{ id: IDS.category, name: 'Frozen Food' }],
          products: [{
            id: IDS.product, sku: 'QA-AYAM', name: 'Ayam Frozen QA',
            categoryId: IDS.category, uomName: 'PACK', allowDecimal: false,
            decimalPrecision: 0,
          }],
          sessions: [{
            id: IDS.stockOpname, opname_no: 'OPN-QA-0001',
            warehouse_id: IDS.warehouse, warehouse_name: 'Gudang Toko',
            status: 'COUNTING', scope_type: 'ALL', category_id: null,
            notes: null, master_version: 2,
            created_at: '2026-11-01T08:00:00.000Z',
            updated_at: '2026-11-01T08:00:00.000Z', line_count: 1,
            pending_count: 1, counted_count: 0,
            recount_required_count: 0, skipped_count: 0,
          }],
        },
        get_pos_stock_opname_count_review: {
          opnameId: IDS.stockOpname, opnameNo: 'OPN-QA-0001',
          warehouseId: IDS.warehouse, status: 'COUNTING', masterVersion: 2,
          lines: [{
            detailId: IDS.stockOpnameDetail, productId: IDS.product,
            sku: 'QA-AYAM', productName: 'Ayam Frozen QA', uomName: 'PACK',
            lineStatus: 'PENDING', notes: null, enteredQuantity: null, canEdit: true,
          }],
        },
        record_stock_opname_count: { lineStatus: 'COUNTED', masterVersion: 3 },
        complete_stock_opname_partial: {
          opnameId: IDS.stockOpname, status: 'COMPLETED', masterVersion: 4,
          skippedLineCount: 0,
        },
        list_cash_deposit_eligible_sessions: [{
          sessionId: IDS.closedSession, sessionCode: 'SES-QA-CLOSED',
          cashierId: IDS.user, cashierName: 'Kasir QA',
          closedAt: '2026-11-01T07:00:00.000Z', closingCashActual: 150000,
          postedDepositAllocations: 0, availableDepositAmount: 150000,
        }],
        save_cash_deposit_draft: {
          depositDocumentId: IDS.cashDeposit, depositNo: 'DEP-QA-0001',
          status: 'DRAFT', masterVersion: 1, totalExpectedDeposit: 150000,
          actualDepositAmount: 150000, depositVariance: 0,
          varianceType: 'NONE', idempotentReplay: false,
        },
        submit_cash_deposit: {
          depositDocumentId: IDS.cashDeposit, status: 'SUBMITTED',
          masterVersion: 2, totalExpectedDeposit: 150000,
          depositVariance: 0,
        },
        close_cashier_session: {
          expectedCash: 100000, difference: 0,
          procurementStockRequest: { skipReason: 'COMPANY_POLICY_DISABLED' },
        },
        post_pos_expense: {
          documentId: '90000000-0000-4000-8000-000000000001',
          documentNo: 'EXP-QA-0001',
          disbursementId: '90000000-0000-4000-8000-000000000002',
          status: 'DISBURSED', masterVersion: 2, amount: 30000,
          paymentMethodType: 'CASH', expectedCashAfter: 70000,
          financialEventId: '90000000-0000-4000-8000-000000000003',
          idempotentReplay: false,
        },
        list_pos_sale_drafts: options.zeroPriceDiscountDraft ? [{
          salesId: IDS.sale,
          draftNo: 'DRF-QA-ZERO-PRICE',
          draftLabel: null,
          draftNotes: null,
          draftReason: null,
          customerId: IDS.namedCustomer,
          customerName: 'Customer QA Named',
          storeId: IDS.store,
          storeName: 'Toko Utama',
          salesWarehouseId: IDS.warehouse,
          salesOrigin: 'POS',
          commercialSnapshotPreserved: false,
          createdBy: IDS.user,
          createdByName: 'Kasir QA',
          createdAt: '2026-11-02T01:00:00.000Z',
          transactionAt: '2026-11-02T01:00:00.000Z',
          transactionDateSource: 'SERVER_CREATED',
          orderTimingMode: 'IMMEDIATE',
          plannedOrderDate: null,
          operationalStatus: 'ACTIVE',
          canPost: true,
          updatedAt: '2026-11-03T01:00:00.000Z',
          masterVersion: 1,
          grandTotal: 0,
          lineCount: 1,
          isStale: false,
          lockOwnerId: null,
          lockOwnerName: null,
          lockSessionId: null,
          lockHeartbeatAt: null,
          lockExpired: false,
          payloadSnapshot: {
            clientTransactionId: '70000000-0000-4000-8000-000000000099',
            customerId: IDS.namedCustomer,
            selectedPricelistId: null,
            globalDiscount: 0,
            roundingDirection: 'NONE',
            isTempo: false,
            fulfillmentMode: 'PICKUP',
            lines: [{
              lineKey: IDS.productUom,
              productUomId: IDS.productUom,
              quantity: 1,
              lineDiscountType: 'AMOUNT',
              lineDiscountInput: 100,
              lineDiscountAmountBasis: 'PER_UNIT',
            }],
          },
        }] : [],
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
        save_pos_sale_draft_with_ketul: {
          salesId: IDS.sale, draftNo: 'DRF-QA-0001', masterVersion: 1,
          grandTotalBeforeRounding: 25000, roundingAdjustment: 0,
          grandTotalAfterRounding: 25000, deliveryFeeAmount: 0,
          deliveryFeeInvoiceDisplayMode: 'SHOW_SEPARATE', ketulOffsetTotal: 10000,
          ketulLineCount: 1,
        },
        post_pos_sale_with_ketul: {
          salesId: IDS.sale, documentStatus: 'POSTED', masterVersion: 2,
          ketulOffsetTotal: 10000,
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
        get_pos_returnable_sales: {
          companyId: IDS.company,
          sales: [{
            id: IDS.sale, invoice_no: 'INV-QA-0001',
            transaction_date: '2026-10-30T04:00:00.000Z', store_id: IDS.store,
            customer_id: IDS.namedCustomer, grand_total_after_rounding: 25000,
            priorRefundTotal: 0, deliveryFeeAmount: 0, deliveryFeeRefunded: 0,
            lines: [{
              sourceSalesDetailId: '71000000-0000-4000-8000-000000000001',
              productId: IDS.product, productName: 'Ayam Frozen QA',
              uomName: 'PACK', soldQuantity: 1, returnedQuantity: 0,
              remainingQuantity: 1, refundableLineAmount: 25000,
            }],
          }],
          damagedWarehouses: [],
        },
        save_sales_return_draft_with_delivery_fee: {
          documentId: '81000000-0000-4000-8000-000000000003',
          returnNo: 'RTN-QA-0001', masterVersion: 1, refundTotal: 25000,
        },
        submit_pos_sales_return_with_delivery_fee: {
          documentId: '81000000-0000-4000-8000-000000000003',
          returnNo: 'RTN-QA-0001', status: 'POSTED', masterVersion: 2,
          refundTotal: 25000, approvalMode: 'OPTIONAL',
          financialEventId: '82000000-0000-4000-8000-000000000001',
          idempotentReplay: false,
        },
        open_cashier_session: {
          cashierSessionId: IDS.session, sessionCode: 'SES-QA-KGFF', masterVersion: 1,
        },
      }
      if (rpc === 'preview_pos_sale_prices') {
        const isZeroPrice =
          (options.zeroPriceForNamedCustomer || options.zeroPriceDiscountDraft) &&
          (payload as Record<string, unknown>).p_customer_id === IDS.namedCustomer
        return reply(route, {
          lines: [{
            lineKey: IDS.productUom, productUomId: IDS.productUom,
            productName: 'Ayam Frozen QA', productSku: 'QA-AYAM', uomName: 'PACK',
            quantity: 1, baseUnitPrice: 25000, unitPrice: isZeroPrice ? 0 : 25000,
            pricelistId: IDS.pricelist, pricelistRuleId: null,
            pricelistName: isZeroPrice ? 'Sample SALES KGS' : 'Harga Retail KGFF',
            pricingSelectionSource: 'AUTO',
          }],
        })
      }
      if (rpc === 'save_pos_sale_draft_with_ketul') {
        const isZeroPrice =
          (options.zeroPriceForNamedCustomer || options.zeroPriceDiscountDraft) &&
          ((payload as Record<string, unknown>).p_payload as Record<string, unknown>)
            ?.customerId === IDS.namedCustomer
        return reply(route, {
          ...(responses[rpc] as Record<string, unknown>),
          grandTotalBeforeRounding: isZeroPrice ? 0 : 25000,
          grandTotalAfterRounding: isZeroPrice ? 0 : 25000,
        })
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
        pos_name: 'Kasir Utama POS-1', hidden_feature_keys: [],
        allow_price_override: options.allowPriceOverride ?? false,
      }],
      warehouses: [{ id: IDS.warehouse, store_id: IDS.store, name: 'Gudang Toko' }],
      cashier_sessions: options.sessionOpen === false ? null : {
        id: IDS.session, session_code: 'SES-QA-KGFF', pos_id: IDS.terminal,
        sales_warehouse_id: IDS.warehouse, store_id: IDS.store,
        opening_cash_actual: 100000, expected_cash: 100000, master_version: 1,
      },
      products: [
        { id: IDS.product, sku: 'QA-AYAM', name: 'Ayam Frozen QA', category_id: IDS.category, is_bundle: false, pos_line_discount_amount_basis: 'PER_UNIT' },
        { id: IDS.ketulProduct, sku: 'KTL-QA', name: 'Ketul QA', category_id: IDS.ketulCategory, is_bundle: false, pos_line_discount_amount_basis: 'PER_UNIT' },
        { id: IDS.lettuceProduct, sku: 'L', name: 'Lettuce', category_id: IDS.category, is_bundle: false, pos_line_discount_amount_basis: 'LINE_TOTAL' },
        { id: IDS.bombayProduct, sku: 'BB', name: 'Bawang Bombay', category_id: IDS.category, is_bundle: false, pos_line_discount_amount_basis: 'LINE_TOTAL' },
      ],
      product_uoms: [
        {
          id: IDS.productUom, product_id: IDS.product, uom_id: IDS.uom,
          factor_to_base: 1, sale_price: 25000, barcode: 'QA001',
          is_active: true, sales_allowed: true,
        },
        {
          id: IDS.lettuceProductUom, product_id: IDS.lettuceProduct, uom_id: IDS.uom,
          factor_to_base: 1, sale_price: 10000, barcode: 'L-QA',
          is_active: true, sales_allowed: true,
        },
        {
          id: IDS.bombayProductUom, product_id: IDS.bombayProduct, uom_id: IDS.uom,
          factor_to_base: 1, sale_price: 12000, barcode: 'BB-QA',
          is_active: true, sales_allowed: true,
        },
        {
          id: IDS.ketulProductUom, product_id: IDS.ketulProduct, uom_id: IDS.uom,
          factor_to_base: 1, sale_price: 0, barcode: 'KTLQA',
          is_active: true, sales_allowed: true,
        },
      ],
      uoms: [{ id: IDS.uom, name: 'PACK', allow_decimal: false, decimal_precision: 0 }],
      product_categories: [
        { id: IDS.category, category_name: 'Frozen Food' },
        { id: IDS.ketulCategory, category_name: 'KETUL' },
      ],
      company_features: { is_enabled: true },
      goods_receipt_documents: [],
      goods_receipt_lines: [],
      sales_details: [{
        id: '71000000-0000-4000-8000-000000000001', sales_id: IDS.sale,
        product_id: IDS.product, product_name_snapshot: 'Ayam Frozen QA',
        product_sku_snapshot: 'QA-AYAM', sale_uom_name_snapshot: 'PACK', qty: 1,
        resolved_unit_price: 25000, discount_amount: 0, line_total: 25000,
      }],
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
        } : [{
          id: IDS.sale, invoice_no: 'INV-QA-0001', draft_no: 'DRF-QA-0001',
          customer_id: IDS.namedCustomer, transaction_date: '2026-10-30T04:00:00.000Z',
          planned_order_date: null, document_status: 'POSTED',
          order_runtime_status: 'LEGACY_POSTED', is_tempo: false,
          grand_total: 25000, grand_total_after_rounding: 25000,
          payload_snapshot: { payments: [] }, created_at: '2026-10-30T04:00:00.000Z',
        }],
      sales_payments: [
        {
          id: '72000000-0000-4000-8000-000000000001', sales_id: IDS.sale,
          payment_method: 'Cash', payment_method_id: IDS.payment,
          payment_method_name_snapshot: 'Cash', payment_method_type_snapshot: 'CASH',
          settlement_route_snapshot: 'CASH_DRAWER', amount: 20000, is_reversal: false,
        },
        {
          id: '72000000-0000-4000-8000-000000000002', sales_id: IDS.sale,
          payment_method: 'QRIS', payment_method_id: IDS.qrisPayment,
          payment_method_name_snapshot: 'QRIS', payment_method_type_snapshot: 'QRIS',
          settlement_route_snapshot: 'PAYMENT_CLEARING', amount: 5000, is_reversal: false,
        },
      ],
    }
    const response = rows[table]
    if (response !== undefined) return reply(route, response)
    return reply(route, objectResponse ? null : [])
  })
  return rpcCalls
}

async function addCatalogProductToCart(
  page: Page,
  productName = 'Ayam Frozen QA',
) {
  await page.locator('.pos-product-grid').getByRole('button', {
    name: new RegExp(productName),
  }).click()
  const editor = page.getByRole('dialog', { name: productName })
  await expect(editor).toBeVisible()
  await editor.getByRole('button', { name: 'Masukkan ke keranjang' }).click()
  await expect(editor).toHaveCount(0)
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
  await expect(page.getByLabel('Customer katalog')).toHaveValue(IDS.customer)
  await expect(page.getByRole('button', { name: 'Customer baru' })).toBeVisible()
  await expect(page.getByLabel('Pricelist')).toContainText('Harga Retail KGFF')

  await addCatalogProductToCart(page)
  const catalogCustomer = page.getByLabel('Customer katalog')
  await expect(catalogCustomer).toBeVisible()
  await expect(catalogCustomer).toHaveValue(IDS.customer)
  await catalogCustomer.selectOption(IDS.namedCustomer)
  await expect(catalogCustomer).toHaveValue(IDS.namedCustomer)
  await page.getByRole('button', { name: 'Atur pembayaran' }).click()
  const paymentDialog = page.getByRole('dialog', { name: 'Pembayaran dan penyelesaian' })
  await expect(paymentDialog.getByText('Pembayaran & penyelesaian')).toBeVisible()
  await expect(paymentDialog.getByText('Harga transaksi')).toBeVisible()
  await expect(paymentDialog.getByLabel('Customer', { exact: true })).toHaveCount(0)
  await expect(paymentDialog.getByText('Rp 25.000', { exact: true }).first()).toBeVisible()
  await page.getByRole('button', { name: 'Simpan Draft' }).click()
  await expect(page.getByText(/Draft tersimpan/)).toBeVisible()
  await page.getByRole('button', { name: 'Selesaikan Transaksi' }).click()
  await expect(page.getByText('Transaksi Posted')).toBeVisible()
  await expect(page.getByText('Belum ada barang.')).toBeVisible()
  await expect(page.getByLabel('Customer katalog')).toHaveValue(IDS.customer)
  await expect(page.getByText('INV-QA-0001')).toBeVisible()
  await expect(page.getByTestId('posted-customer-name')).toContainText('Customer QA Named')
  await expect(page.getByRole('button', { name: 'Invoice A4' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Surat Jalan' })).toHaveCount(0)
  await page.getByRole('button', { name: 'Kembali ke kasir' }).click()
  await expect(page.getByText('Belum ada barang.')).toBeVisible()
  await expect(page.getByLabel('Customer katalog')).toHaveValue(IDS.customer)

  for (const required of [
    'get_company_branding',
    'get_pos_stock_availability',
    'get_pos_customer_references',
    'get_pos_pricelist_references',
    'get_pos_payment_method_references',
    'get_pos_ketul_readiness',
    'preview_pos_sale_prices',
    'save_pos_sale_draft_with_ketul',
    'post_pos_sale_with_ketul',
    'get_pos_sales_invoice_document',
  ]) expect(rpcCalls.map((call) => call.name), `Retail flow must call ${required}`).toContain(required)
  expect(rpcCalls.map((call) => call.name), 'Pickup Retail must not enter the Order/reservation runtime').not.toContain('confirm_pos_sales_order')
  expect(rpcCalls.map((call) => call.name), 'Pickup Retail must not create or load a Surat Jalan').not.toContain('get_pos_sales_delivery_document')
})

test('configures a Product before Cart commit and keeps the same editor available afterward', async ({ page }) => {
  await installRetailServerMock(page)
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('not-a-real-password')
  await page.getByRole('button', { name: 'Masuk' }).click()

  const productCard = page.locator('.pos-product-grid').getByRole('button', {
    name: /Ayam Frozen QA/,
  })
  const cartItems = page.locator('.pos-cart-item')

  await productCard.click()
  let editor = page.getByRole('dialog', { name: 'Ayam Frozen QA' })
  await expect(editor).toBeVisible()
  await expect(editor.getByText('Tambah produk')).toBeVisible()
  await expect(cartItems).toHaveCount(0)
  await editor.getByRole('button', { name: 'Batal', exact: true }).click()
  await expect(editor).toHaveCount(0)
  await expect(cartItems).toHaveCount(0)

  await productCard.click()
  editor = page.getByRole('dialog', { name: 'Ayam Frozen QA' })
  await expect(editor).toBeVisible()
  await page.keyboard.press('Escape')
  await expect(editor).toHaveCount(0)
  await expect(cartItems).toHaveCount(0)

  await productCard.click()
  editor = page.getByRole('dialog', { name: 'Ayam Frozen QA' })
  await editor.locator('.pos-cart-editor-quantity input').fill('2')
  await editor.locator('.pos-cart-editor-discount select').selectOption('PERCENT')
  await editor.locator('.pos-cart-editor-discount input').fill('10')
  await expect(cartItems).toHaveCount(0)
  await editor.getByRole('button', { name: 'Masukkan ke keranjang' }).click()

  await expect(cartItems).toHaveCount(1)
  await expect(cartItems.first()).toContainText('2 PACK')
  await expect(cartItems.first()).toContainText('Diskon 10%')
  await cartItems.first().getByRole('button', { name: /Edit Ayam Frozen QA/ }).click()
  editor = page.getByRole('dialog', { name: 'Ayam Frozen QA' })
  await expect(editor.getByText('Edit produk')).toBeVisible()
  await editor.locator('.pos-cart-editor-quantity input').fill('3')
  await editor.getByRole('button', { name: 'Selesai' }).click()
  await expect(cartItems.first()).toContainText('3 PACK')

  await productCard.click()
  editor = page.getByRole('dialog', { name: 'Ayam Frozen QA' })
  await expect(editor.getByText('Edit produk')).toBeVisible()
  await expect(cartItems).toHaveCount(1)
  await editor.getByRole('button', { name: 'Selesai' }).click()

  await page.getByRole('button', { name: 'Compact' }).click()
  await page.getByRole('button', { name: 'Tambah produk' }).click()
  await page.locator('#pos-product-picker-menu').getByRole('button', {
    name: /Ayam Frozen QA/,
  }).click()
  editor = page.getByRole('dialog', { name: 'Ayam Frozen QA' })
  await expect(editor.getByText('Edit produk')).toBeVisible()
  await expect(cartItems).toHaveCount(1)
  await editor.getByRole('button', { name: 'Selesai' }).click()
})

test('removes a stale Product discount when Customer Pricelist resolves the line to zero', async ({ page }) => {
  const rpcCalls = await installRetailServerMock(page, {
    zeroPriceForNamedCustomer: true,
  })
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('not-a-real-password')
  await page.getByRole('button', { name: 'Masuk' }).click()

  await page.locator('.pos-product-grid').getByRole('button', {
    name: /Ayam Frozen QA/,
  }).click()
  const editor = page.getByRole('dialog', { name: 'Ayam Frozen QA' })
  await editor.locator('.pos-cart-editor-discount select').selectOption('AMOUNT')
  await editor.locator('.pos-cart-editor-discount input').fill('100')
  await editor.getByRole('button', { name: 'Masukkan ke keranjang' }).click()

  await page.getByLabel('Customer katalog').selectOption(IDS.namedCustomer)
  await expect(page.getByText(
    'Diskon produk lama dihapus karena harga Pricelist produk tersebut Rp0.',
  )).toBeVisible()
  await expect(
    page.locator('.pos-cart-item').first().locator('.pos-catalog-cart-notes'),
  ).toHaveCount(0)

  await page.getByRole('button', { name: 'Atur pembayaran' }).click()
  await page.getByRole('button', { name: 'Simpan Draft' }).click()
  await expect(page.getByText(/Draft tersimpan/)).toBeVisible()

  const saveCall = [...rpcCalls]
    .reverse()
    .find((call) => call.name === 'save_pos_sale_draft_with_ketul')
  const savePayload = saveCall?.payload as {
    p_payload?: { lines?: Array<Record<string, unknown>>; globalDiscount?: number }
  }
  expect(savePayload.p_payload?.lines).toEqual([{
    lineKey: IDS.productUom,
    productUomId: IDS.productUom,
    quantity: 1,
  }])
  expect(savePayload.p_payload?.globalDiscount).toBe(0)
})

test('continues an existing zero-price Draft after removing its stale Product discount', async ({ page }) => {
  const rpcCalls = await installRetailServerMock(page, {
    zeroPriceDiscountDraft: true,
  })
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('not-a-real-password')
  await page.getByRole('button', { name: 'Masuk' }).click()

  await page.getByRole('button', { name: /^Draft/ }).click()
  const draftPanel = page.getByRole('heading', { name: 'Draft transaksi' })
    .locator('xpath=ancestor::section[1]')
  await expect(draftPanel.getByText('DRF-QA-ZERO-PRICE')).toBeVisible()
  await draftPanel.getByRole('button', { name: 'Lanjutkan' }).click()

  await expect(page.getByText(
    'DRF-QA-ZERO-PRICE dibuka; diskon produk lama dihapus karena harga Pricelist Rp0.',
  )).toBeVisible()
  await expect(page.getByText('LINE_DISCOUNT_EXCEEDS_LINE_TOTAL')).toHaveCount(0)
  const saveCall = [...rpcCalls]
    .reverse()
    .find((call) => call.name === 'save_pos_sale_draft_with_ketul')
  const savePayload = saveCall?.payload as {
    p_payload?: { lines?: Array<Record<string, unknown>> }
  }
  expect(savePayload.p_payload?.lines).toEqual([{
    lineKey: IDS.productUom,
    productUomId: IDS.productUom,
    quantity: 1,
  }])
})

test('keeps a Product discount when an allowed positive price override replaces the zero Pricelist price', async ({ page }) => {
  const rpcCalls = await installRetailServerMock(page, {
    zeroPriceForNamedCustomer: true,
    allowPriceOverride: true,
  })
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('not-a-real-password')
  await page.getByRole('button', { name: 'Masuk' }).click()
  await page.getByLabel('Customer katalog').selectOption(IDS.namedCustomer)

  await page.locator('.pos-product-grid').getByRole('button', {
    name: /Ayam Frozen QA/,
  }).click()
  const editor = page.getByRole('dialog', { name: 'Ayam Frozen QA' })
  const priceSection = editor.locator('.pos-cart-editor-section').filter({
    hasText: 'Harga jual / PACK',
  })
  await priceSection.locator('input').fill('5000')
  await editor.locator('.pos-cart-editor-discount select').selectOption('AMOUNT')
  await editor.locator('.pos-cart-editor-discount input').fill('100')
  await editor.getByRole('button', { name: 'Masukkan ke keranjang' }).click()
  await page.getByRole('button', { name: 'Atur pembayaran' }).click()
  await page.getByRole('button', { name: 'Simpan Draft' }).click()

  const saveCall = [...rpcCalls]
    .reverse()
    .find((call) => call.name === 'save_pos_sale_draft_with_ketul')
  const savePayload = saveCall?.payload as {
    p_payload?: { lines?: Array<Record<string, unknown>> }
  }
  expect(savePayload.p_payload?.lines).toEqual([{
    lineKey: IDS.productUom,
    productUomId: IDS.productUom,
    quantity: 1,
    lineDiscountType: 'AMOUNT',
    lineDiscountInput: 100,
    lineDiscountAmountBasis: 'PER_UNIT',
    overrideUnitPrice: 5000,
  }])
})

test('previews nominal Product discounts per unit while Lettuce and Bawang Bombay stay whole-line', async ({ page }) => {
  await page.setViewportSize({ width: 1920, height: 900 })
  await installRetailServerMock(page)
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('not-a-real-password')
  await page.getByRole('button', { name: 'Masuk' }).click()

  async function expectAmountPreview(
    productName: string,
    expectedTotal: string,
    expectedBasisCopy: string,
  ) {
    await page.locator('.pos-product-grid').getByRole('button', {
      name: new RegExp(productName),
    }).click()
    const editor = page.getByRole('dialog', { name: productName })
    await editor.locator('.pos-cart-editor-quantity input').fill('10')
    await editor.locator('.pos-cart-editor-discount select').selectOption('AMOUNT')
    await editor.locator('.pos-cart-editor-discount input').fill('100')
    await expect(editor.getByText(expectedBasisCopy)).toBeVisible()
    await expect(editor.locator('.pos-cart-editor-quantity strong')).toHaveText(
      expectedTotal,
    )
    await editor.getByRole('button', { name: 'Batal', exact: true }).click()
  }

  await expectAmountPreview(
    'Ayam Frozen QA',
    'Rp 249.000',
    'Nominal berlaku per PACK.',
  )
  await expectAmountPreview(
    'Lettuce',
    'Rp 99.900',
    'Nominal berlaku untuk total baris produk ini.',
  )
  await expectAmountPreview(
    'Bawang Bombay',
    'Rp 119.900',
    'Nominal berlaku untuk total baris produk ini.',
  )
})

test('uses the desktop Catalog height for Cart items and keeps Total Akhir at the panel bottom', async ({ page }, testInfo) => {
  await page.setViewportSize({ width: 1920, height: 900 })
  await installRetailServerMock(page)
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('not-a-real-password')
  await page.getByRole('button', { name: 'Masuk' }).click()

  const productSearch = page.getByPlaceholder('Cari nama, SKU, barcode, atau satuan...')
  const categoryStrip = page.locator('.pos-catalog-category-tabs')
  const productGrid = page.locator('.pos-product-grid')
  await expect(categoryStrip).toBeVisible()
  await expect(categoryStrip.getByRole('button', { name: 'Semua' })).toBeVisible()
  const [searchBox, categoryBox, productGridBox] = await Promise.all([
    productSearch.boundingBox(),
    categoryStrip.boundingBox(),
    productGrid.boundingBox(),
  ])
  expect(searchBox).not.toBeNull()
  expect(categoryBox).not.toBeNull()
  expect(productGridBox).not.toBeNull()
  expect(categoryBox!.height, 'Category strip must not collapse behind Product cards').toBeGreaterThanOrEqual(30)
  expect(categoryBox!.height, 'Category strip must remain compact').toBeLessThanOrEqual(36)
  expect(
    categoryBox!.y,
    'Category strip must be placed below Product search',
  ).toBeGreaterThanOrEqual(searchBox!.y + searchBox!.height)
  expect(
    productGridBox!.y,
    'Product grid must start after the complete category strip',
  ).toBeGreaterThanOrEqual(categoryBox!.y + categoryBox!.height - 1)
  await categoryStrip.getByRole('button', { name: 'KETUL' }).click()
  await expect(page.getByRole('button', { name: /Ketul QA/ })).toBeVisible()
  await expect(page.getByRole('button', { name: /Ayam Frozen QA/ })).toHaveCount(0)
  await categoryStrip.getByRole('button', { name: 'Semua' }).click()
  await addCatalogProductToCart(page)

  const cartPanel = page.locator('.pos-cart-panel')
  const cartList = page.locator('.pos-cart-list')
  const totalFooter = page.locator('.pos-cart-total-footer')
  const catalogPanel = page.locator('.pos-catalog')
  const [panelBox, listBox, footerBox] = await Promise.all([
    cartPanel.boundingBox(),
    cartList.boundingBox(),
    totalFooter.boundingBox(),
  ])

  expect(panelBox).not.toBeNull()
  expect(listBox).not.toBeNull()
  expect(footerBox).not.toBeNull()
  expect(listBox!.height, 'Cart list must no longer use the rejected 224px cap').toBeGreaterThan(224)
  expect(
    Math.abs(
      panelBox!.y + panelBox!.height - (footerBox!.y + footerBox!.height),
    ),
    'Total Akhir footer must terminate at the bottom edge of the Cart panel',
  ).toBeLessThanOrEqual(2)
  expect(
    page.viewportSize()!.height - (panelBox!.y + panelBox!.height),
    'The desktop Cart panel must use the visible lower viewport instead of ending mid-screen',
  ).toBeLessThanOrEqual(48)
  const geometryEvidence = {
    viewport: page.viewportSize(),
    panel: panelBox,
    list: listBox,
    footer: footerBox,
    viewportBottomGap:
      page.viewportSize()!.height - (panelBox!.y + panelBox!.height),
    footerPanelBottomDelta: Math.abs(
      panelBox!.y + panelBox!.height - (footerBox!.y + footerBox!.height),
    ),
  }
  console.log(`POINT7_GEOMETRY ${JSON.stringify(geometryEvidence)}`)
  await testInfo.attach('catalog-cart-geometry.json', {
    body: Buffer.from(JSON.stringify(geometryEvidence, null, 2)),
    contentType: 'application/json',
  })
  await testInfo.attach('catalog-cart-viewport.png', {
    body: await page.screenshot(),
    contentType: 'image/png',
  })
  await catalogPanel.evaluate((element) => {
    const spacer = document.createElement('div')
    spacer.dataset.testScrollSpacer = 'true'
    spacer.style.flex = '0 0 1600px'
    element.appendChild(spacer)
  })
  await catalogPanel.evaluate((element) => {
    element.scrollTop = 500
  })
  await expect
    .poll(() => catalogPanel.evaluate((element) => element.scrollTop))
    .toBeGreaterThan(0)
  const footerAfterCatalogScroll = await totalFooter.boundingBox()
  expect(footerAfterCatalogScroll).not.toBeNull()
  expect(
    Math.abs(footerAfterCatalogScroll!.x - footerBox!.x),
    'Catalog scroll must not move the fixed Cart footer horizontally',
  ).toBeLessThanOrEqual(1)
  expect(
    Math.abs(footerAfterCatalogScroll!.y - footerBox!.y),
    'Catalog scroll must not move the fixed Cart footer vertically',
  ).toBeLessThanOrEqual(1)
  expect(
    await page.evaluate(() => window.scrollY),
    'Catalog must own desktop scrolling instead of the browser window',
  ).toBe(0)
  console.log(`POINT7_FIXED_FOOTER ${JSON.stringify({
    before: footerBox,
    afterCatalogScroll: footerAfterCatalogScroll,
    catalogScrollTop: await catalogPanel.evaluate((element) => element.scrollTop),
  })}`)
  await testInfo.attach('catalog-cart-fixed-after-scroll.png', {
    body: await page.screenshot(),
    contentType: 'image/png',
  })
  await catalogPanel.evaluate((element) => {
    element.scrollTop = 0
    element.querySelector('[data-test-scroll-spacer="true"]')?.remove()
  })
  await expect(totalFooter.getByText('Total akhir')).toBeVisible()
  await page.getByRole('button', { name: 'Compact' }).click()
  await expect
    .poll(() => page.locator('.pos-order-column').evaluate(
      (element) => window.getComputedStyle(element).display,
    ))
    .toBe('contents')

  await page.getByRole('button', { name: 'Katalog' }).click()
  await page.setViewportSize({ width: 390, height: 844 })
  await expect(categoryStrip).toBeVisible()
  await expect
    .poll(() => categoryStrip.evaluate((element) => element.getBoundingClientRect().height))
    .toBeGreaterThanOrEqual(30)
  await expect
    .poll(() => page.locator('.pos-order-column').evaluate(
      (element) => window.getComputedStyle(element).display,
    ))
    .toBe('contents')

  await page.setViewportSize({ width: 1920, height: 900 })
  await totalFooter.getByRole('button', { name: 'Atur pembayaran' }).click()
  await expect(page.getByRole('dialog', {
    name: 'Pembayaran dan penyelesaian',
  })).toBeVisible()
})

test('applies a ready Company Ketul intake as a hidden post-tax offset without exposing it as a payment choice', async ({ page }, testInfo) => {
  const rpcCalls = await installRetailServerMock(page)
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('not-a-real-password')
  await page.getByRole('button', { name: 'Masuk' }).click()

  await addCatalogProductToCart(page)
  await page.getByRole('button', { name: 'Atur pembayaran' }).click()
  const ketulEntry = page.locator('.pos-ketul-entry')
  await expect(ketulEntry).toBeVisible()
  await expect(ketulEntry).toContainText('Ketul masuk stok')
  await page.getByRole('button', { name: 'Tambah Ketul' }).click()

  const ketulDialog = page.getByRole('dialog', { name: 'Pengembalian Ketul' })
  await expect(ketulDialog).toBeVisible()
  await expect(ketulDialog.locator('.pos-ketul-line')).toHaveCount(1)
  await testInfo.attach('ketul-editor-desktop.png', {
    body: await page.screenshot(),
    contentType: 'image/png',
  })
  await page.setViewportSize({ width: 390, height: 844 })
  await expect(ketulDialog).toBeVisible()
  await expect
    .poll(() => ketulDialog.evaluate((element) => element.scrollWidth <= element.clientWidth))
    .toBe(true)
  await expect(ketulDialog.getByRole('button', { name: 'Terapkan Potongan' })).toBeVisible()
  await testInfo.attach('ketul-editor-mobile.png', {
    body: await page.screenshot(),
    contentType: 'image/png',
  })
  await page.setViewportSize({ width: 1920, height: 900 })
  await ketulDialog.getByLabel('Jenis Ketul').selectOption(IDS.ketulProduct)
  await ketulDialog.getByLabel('Qty').fill('2')
  await ketulDialog.getByLabel('Harga per unit').fill('5000')
  await ketulDialog.getByRole('button', { name: 'Terapkan Potongan' }).click()

  await expect(page.getByText('1 jenis Ketul')).toBeVisible()
  await expect(page.getByText('-Rp 10.000').first()).toBeVisible()
  const paymentDialog = page.getByRole('dialog', { name: 'Pembayaran dan penyelesaian' })
  await expect(paymentDialog.getByRole('option', { name: 'Potongan Ketul' })).toHaveCount(0)
  await page.getByRole('button', { name: 'Selesaikan Transaksi' }).click()
  await expect(page.getByText('Transaksi Posted')).toBeVisible()

  const saveCalls = rpcCalls.filter((call) => call.name === 'save_pos_sale_draft_with_ketul')
  expect(saveCalls.length).toBeGreaterThanOrEqual(2)
  const finalPayload = (saveCalls.at(-1)?.payload as {
    p_payload?: {
      ketulIntakeLines?: Array<{ productId: string; quantity: number; unitPrice: number }>
      payments?: Array<{ amount: number }>
    }
  }).p_payload
  expect(finalPayload?.ketulIntakeLines).toEqual([
    { productId: IDS.ketulProduct, quantity: 2, unitPrice: 5000 },
  ])
  expect(finalPayload?.payments).toHaveLength(1)
  expect(finalPayload?.payments?.[0]?.amount).toBe(15000)
  expect(rpcCalls.map((call) => call.name)).toContain('post_pos_sale_with_ketul')
  expect(rpcCalls.map((call) => call.name)).toContain('get_pos_ketul_readiness')
})

test('keeps the Ketul action fail-closed when Company entitlement exists but server readiness is incomplete', async ({ page }) => {
  const rpcCalls = await installRetailServerMock(page, { ketulReady: false })
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('not-a-real-password')
  await page.getByRole('button', { name: 'Masuk' }).click()

  await addCatalogProductToCart(page)
  await page.getByRole('button', { name: 'Atur pembayaran' }).click()
  await expect(page.getByRole('button', { name: 'Tambah Ketul' })).toHaveCount(0)
  expect(rpcCalls.map((call) => call.name)).toContain('get_pos_ketul_readiness')
})

test('keeps Cash metadata-free and accepts optional Transfer refund metadata', async ({ page }) => {
  const rpcCalls = await installRetailServerMock(page)
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('not-a-real-password')
  await page.getByRole('button', { name: 'Masuk' }).click()

  await page.getByRole('button', { name: 'Return', exact: true }).click()
  const returnDialog = page.getByRole('dialog', { name: 'Return Penjualan' })
  await expect(returnDialog.getByText('INV-QA-0001')).toBeVisible()
  await returnDialog.getByRole('button', { name: /INV-QA-0001/ }).click()
  await returnDialog.getByLabel(/Ayam Frozen QA/).check()

  const refundMethod = returnDialog.getByLabel('Cara refund')
  await expect(refundMethod).toHaveValue(IDS.payment)
  await expect(returnDialog.getByText(/Tujuan transfer dan nomor referensi tidak diperlukan/)).toBeVisible()
  await expect(returnDialog.getByLabel('Tujuan transfer')).toHaveCount(0)
  await expect(returnDialog.getByLabel('Nomor referensi')).toHaveCount(0)

  await refundMethod.selectOption(IDS.transferPayment)
  await expect(returnDialog.getByLabel('Tujuan transfer')).toBeVisible()
  await expect(returnDialog.getByLabel('Nomor referensi')).toBeVisible()
  await expect(returnDialog.getByLabel('Tujuan transfer')).not.toHaveAttribute('required', '')
  await expect(returnDialog.getByLabel('Nomor referensi')).not.toHaveAttribute('required', '')
  await expect(returnDialog.getByText(/Detail Transfer berikut opsional/)).toBeVisible()
  await returnDialog.getByLabel('Tujuan transfer').fill('BCA 123')
  await returnDialog.getByLabel('Nomor referensi').fill('TRX-QA-001')

  await refundMethod.selectOption(IDS.payment)
  await expect(returnDialog.getByLabel('Tujuan transfer')).toHaveCount(0)
  await refundMethod.selectOption(IDS.transferPayment)
  await expect(returnDialog.getByLabel('Tujuan transfer')).toHaveValue('')
  await expect(returnDialog.getByLabel('Nomor referensi')).toHaveValue('')
  await returnDialog.getByRole('button', { name: 'Konfirmasi Return & Refund' }).click()
  await expect(page.getByText(/RTN-QA-0001 berhasil.*sudah final/)).toBeVisible()
  expect(rpcCalls.find((call) =>
    call.name === 'submit_pos_sales_return_with_delivery_fee')?.payload
  ).toMatchObject({
    p_refunds: [{
      paymentMethodId: IDS.transferPayment,
      transferDestination: null,
      transferReference: null,
      proofUrl: null,
    }],
  })
})

test('records a POS Expense as paid once and keeps the legacy cash disbursement action hidden', async ({ page }) => {
  const rpcCalls = await installRetailServerMock(page)
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('not-a-real-password')
  await page.getByRole('button', { name: 'Masuk' }).click()

  await page.getByRole('button', { name: 'Expense', exact: true }).click()
  const dialog = page.getByRole('dialog', { name: 'Expense Operasional' })
  await expect(dialog.getByRole('button', { name: /Catat Expense/ })).toBeVisible()
  await expect(dialog.getByRole('button', { name: /Cairkan Tunai/ })).toHaveCount(0)
  await dialog.getByLabel('Nominal Expense').fill('30000')
  await dialog.getByLabel('Keperluan Expense').fill('Bensin operasional toko')
  await dialog.getByRole('button', { name: 'Simpan Expense' }).click()

  await expect(page.getByText(/EXP-QA-0001.*sudah dibayar/)).toBeVisible()
  const calls = rpcCalls.filter((call) => call.name === 'post_pos_expense')
  expect(calls).toHaveLength(1)
  expect(calls[0]?.payload).toMatchObject({
    p_store_id: IDS.store,
    p_cashier_session_id: IDS.session,
    p_category_id: IDS.expenseCategory,
    p_requested_amount: 30000,
    p_payment_method_id: IDS.payment,
  })
  expect(rpcCalls.map((call) => call.name)).not.toContain('submit_expense_request')
  expect(rpcCalls.map((call) => call.name)).not.toContain('disburse_expense')
})

test('shows a compact Session Summary while retaining customer, DRF and Invoice identifiers', async ({ page }, testInfo) => {
  await installRetailServerMock(page)
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('not-a-real-password')
  await page.getByRole('button', { name: 'Masuk' }).click()

  await page.getByRole('button', { name: 'Buka ringkasan sesi' }).click()
  const summary = page.getByRole('dialog', { name: /Ringkasan SES-QA-KGFF/ })
  await expect(summary).toBeVisible()
  const totalCards = summary.locator('.pos-session-summary-totals article')
  await expect(totalCards).toHaveCount(5)
  const cardBoxes = await totalCards.evaluateAll((cards) => cards.map((card) => {
    const box = card.getBoundingClientRect()
    return { x: box.x, y: box.y, width: box.width, height: box.height }
  }))
  expect(new Set(cardBoxes.map((box) => Math.round(box.y))).size,
    'Desktop Session Summary totals must stay on one row').toBe(1)
  const summaryList = summary.locator('.pos-session-summary-list')
  await expect(summaryList).toBeVisible()
  const summaryBox = await summary.boundingBox()
  const listBox = await summaryList.boundingBox()
  expect(listBox?.height ?? 0, 'Session transaction list must retain its usable minimum').toBeGreaterThanOrEqual(140)
  expect(
    (listBox?.y ?? Number.POSITIVE_INFINITY) - (summaryBox?.y ?? 0),
    'Compact controls must leave the list near the upper half of the dialog',
  ).toBeLessThan(360)
  console.log(`SESSION_SUMMARY_COMPACT ${JSON.stringify({ cardBoxes, summaryBox, listBox })}`)
  await testInfo.attach('session-summary-compact.png', {
    body: await page.screenshot(),
    contentType: 'image/png',
  })
  await expect(summary.getByText('Uang awal sesi')).toBeVisible()
  await expect(summary.getByText('Rp 100.000')).toBeVisible()
  await expect(summary.getByText('Total Expense')).toBeVisible()
  await expect(summary.getByText('Rp 40.000')).toBeVisible()
  const cashNet = summary.locator('article').filter({ hasText: /^Cash net sesi/ })
  await expect(cashNet).toContainText('Rp 15.000')
  const nonCashNet = summary.locator('article').filter({ hasText: /^Non-cash net sesi/ })
  await expect(nonCashNet).toContainText('Rp 4.000')
  const paymentNet = summary.locator('article').filter({ hasText: /^Total pembayaran net/ })
  await expect(paymentNet).toContainText('Rp 19.000')
  const expenseSummary = summary.locator('article').filter({ hasText: 'Total Expense' })
  await expect(expenseSummary).toContainText('2 transaksi')
  await expect(expenseSummary).toContainText('Cash Rp 30.000')
  await expect(expenseSummary).toContainText('Non-cash Rp 10.000')
  const breakdown = summary.getByLabel('Breakdown metode pembayaran')
  await expect(breakdown).toContainText('Cash')
  await expect(breakdown).toContainText('Rp 15.000')
  await expect(breakdown).toContainText('QRIS')
  await expect(breakdown).toContainText('Rp 4.000')
  await summary.getByRole('tab', { name: /Produk keluar net/ }).click()
  await expect(summary.getByText('0,75 PACK')).toBeVisible()
  await summary.getByRole('tab', { name: /Transaksi/ }).click()
  const transaction = summary.locator('.pos-session-transaction-head').first()
  await expect(transaction.locator('strong').first()).toHaveText('Customer QA Named')
  await expect(transaction.locator('small')).toContainText('DRF-QA-0001')
  await expect(transaction.locator('small')).toContainText('INV-QA-0001')
  const returnShortcut = summary.getByRole('button', {
    name: 'Return transaksi Customer QA Named',
  })
  await expect(returnShortcut).toBeVisible()
  await transaction.click()
  await expect(summary.getByText('Pembayaran tercatat · Split payment')).toBeVisible()
  await returnShortcut.click()
  const returnDialog = page.getByRole('dialog', { name: 'Return Penjualan' })
  await expect(returnDialog).toBeVisible()
  await expect(
    returnDialog.getByText(/INV-QA-0001.*pilih barang yang dikembalikan/),
  ).toBeVisible()
  await expect(returnDialog.getByLabel(/Ayam Frozen QA/)).toBeVisible()
})

test('creates a Company-scoped Customer from the Catalog toolbar with optional fields left empty', async ({ page }) => {
  const rpcCalls = await installRetailServerMock(page)
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('secret')
  await page.getByRole('button', { name: 'Masuk' }).click()

  await page.getByRole('button', { name: 'Customer baru' }).click()
  const dialog = page.getByRole('dialog', { name: 'Tambah Customer' })
  await dialog.getByLabel('Nama Customer').fill('Customer Baru QA')
  await dialog.getByLabel('Tipe Customer').selectOption('BUSINESS')
  await dialog.getByRole('button', { name: 'Simpan Customer' }).click()

  await expect(page.getByText('Customer baru dibuat dan langsung dipilih.')).toBeVisible()
  expect(rpcCalls.find((call) => call.name === 'quick_create_pos_customer')?.payload).toEqual({
    p_customer_name: 'Customer Baru QA',
    p_phone: null,
    p_email: null,
    p_address: null,
    p_customer_type: 'BUSINESS',
  })
})

test('opens a new Cashier Session with the selected terminal, warehouse and physical cash', async ({ page }) => {
  const rpcCalls = await installRetailServerMock(page, { sessionOpen: false })
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('secret')
  await page.getByRole('button', { name: 'Masuk' }).click()

  await expect(page.getByRole('heading', { name: 'Buka Sesi Kasir' })).toBeVisible()
  await page.getByLabel('Modal kas fisik').fill('100000')
  await page.getByRole('button', { name: 'Buka Sesi' }).click()

  await expect(page.getByText('Sesi kasir berhasil dibuka. Snapshot stok awal sudah disimpan.')).toBeVisible()
  expect(rpcCalls.find((call) => call.name === 'open_cashier_session')?.payload).toEqual({
    p_pos_terminal_id: IDS.terminal,
    p_sales_warehouse_id: IDS.warehouse,
    p_opening_cash_actual: 100000,
  })
})

test('saves a Walk-In Delivery Draft without requiring a regular Customer', async ({ page }) => {
  const rpcCalls = await installRetailServerMock(page)
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('secret')
  await page.getByRole('button', { name: 'Masuk' }).click()

  await addCatalogProductToCart(page)
  await page.getByRole('button', { name: 'Atur pembayaran' }).click()
  const checkout = page.getByRole('dialog', { name: 'Pembayaran dan penyelesaian' })
  await checkout.getByLabel('Perlu dikirim').check()
  const delivery = page.getByRole('dialog', { name: 'Tujuan kirim dan ongkir' })
  await expect(delivery.getByLabel('Nama penerima')).toHaveValue('Customer Umum KGFF')
  await delivery.getByLabel('Alamat pengiriman (opsional)').fill('Alamat QA')
  await delivery.getByRole('textbox', { name: 'Ongkir', exact: true }).fill('5000')
  await delivery.getByRole('button', { name: 'Simpan pengiriman' }).click()
  await checkout.getByRole('button', { name: 'Simpan Draft' }).click()

  await expect(page.getByText(/Draft tersimpan/)).toBeVisible()
  const save = rpcCalls.filter((call) => call.name === 'save_pos_sale_draft_with_ketul').at(-1)
  expect(save?.payload).toMatchObject({
    p_payload: {
      fulfillmentMode: 'DELIVERY',
      customerId: IDS.customer,
      deliveryRecipientName: 'Customer Umum KGFF',
      deliveryAddress: 'Alamat QA',
      deliveryFeeAmount: 5000,
    },
  })
  expect(rpcCalls.some((call) => call.name === 'post_pos_sale_with_ketul')).toBe(false)
})

test('keeps a named Customer as the editable Delivery recipient default', async ({ page }) => {
  await installRetailServerMock(page)
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('secret')
  await page.getByRole('button', { name: 'Masuk' }).click()

  await page.getByLabel('Customer katalog').selectOption(IDS.namedCustomer)
  await addCatalogProductToCart(page)
  await page.getByRole('button', { name: 'Atur pembayaran' }).click()
  const checkout = page.getByRole('dialog', { name: 'Pembayaran dan penyelesaian' })
  await checkout.getByLabel('Perlu dikirim').check()
  const delivery = page.getByRole('dialog', { name: 'Tujuan kirim dan ongkir' })
  const recipient = delivery.getByLabel('Nama penerima')
  await expect(recipient).toHaveValue('Customer QA Named')
  await recipient.fill('Penerima QA yang berbeda')
  await expect(recipient).toHaveValue('Penerima QA yang berbeda')
})

test('finalizes a Retail Cash Sales Return and refund with exact source linkage', async ({ page }) => {
  const rpcCalls = await installRetailServerMock(page)
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('secret')
  await page.getByRole('button', { name: 'Masuk' }).click()

  await page.getByRole('button', { name: 'Return', exact: true }).click()
  const dialog = page.getByRole('dialog', { name: 'Return Penjualan' })
  await dialog.getByRole('button', { name: /INV-QA-0001/ }).click()
  await dialog.getByRole('checkbox').check()
  await dialog.getByLabel('Qty Return').fill('1')
  await dialog.getByLabel('Cara refund').selectOption(IDS.payment)
  await dialog.getByRole('button', { name: 'Konfirmasi Return & Refund' }).click()

  await expect(page.getByText(/RTN-QA-0001 berhasil.*sudah final/)).toBeVisible()
  expect(rpcCalls.find((call) => call.name === 'submit_pos_sales_return_with_delivery_fee')?.payload).toMatchObject({
    p_source_sales_id: IDS.sale,
    p_executing_session_id: IDS.session,
    p_lines: [{
      sourceSalesDetailId: '71000000-0000-4000-8000-000000000001',
      quantity: 1,
      condition: 'SALEABLE',
      destinationWarehouseId: null,
    }],
    p_refunds: [{ paymentMethodId: IDS.payment, amount: 25000 }],
    p_operation_id: expect.any(String),
  })
})

test('posts a balanced Cash and QRIS split while preserving each payment leg', async ({ page }) => {
  const rpcCalls = await installRetailServerMock(page)
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('secret')
  await page.getByRole('button', { name: 'Masuk' }).click()

  await addCatalogProductToCart(page)
  await page.getByRole('button', { name: 'Atur pembayaran' }).click()
  const dialog = page.getByRole('dialog', { name: 'Pembayaran dan penyelesaian' })
  await dialog.getByRole('button', { name: 'Simpan Draft' }).click()
  await dialog.getByRole('button', { name: 'Tambah cara bayar' }).click()
  const legs = dialog.locator('.pos-payment-leg-card')
  await expect(legs).toHaveCount(2)
  await legs.nth(1).getByLabel('Cara bayar').selectOption(IDS.qrisPayment)
  await legs.nth(0).locator('input[id^="payment-amount-"]').fill('15000')
  await legs.nth(1).locator('input[id^="payment-amount-"]').fill('10000')
  await dialog.getByRole('button', { name: 'Selesaikan Transaksi' }).click()

  await expect(page.getByText('Transaksi Posted')).toBeVisible()
  const saveCalls = rpcCalls.filter((call) => call.name === 'save_pos_sale_draft_with_ketul')
  const finalPayload = saveCalls.at(-1)?.payload as { p_payload?: { payments?: Array<Record<string, unknown>> } }
  expect(finalPayload.p_payload?.payments).toMatchObject([
    { paymentMethodId: IDS.payment, amount: 15000, tenderedAmount: 15000 },
    { paymentMethodId: IDS.qrisPayment, amount: 10000, tenderedAmount: 10000 },
  ])
})

test('saves Tempo as a dated Draft without creating a direct payment leg or final post', async ({ page }) => {
  const rpcCalls = await installRetailServerMock(page)
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('secret')
  await page.getByRole('button', { name: 'Masuk' }).click()

  await page.getByLabel('Customer katalog').selectOption(IDS.namedCustomer)
  await addCatalogProductToCart(page)
  await page.getByRole('button', { name: 'Atur pembayaran' }).click()
  const dialog = page.getByRole('dialog', { name: 'Pembayaran dan penyelesaian' })
  await dialog.getByLabel('Transaksi TEMPO').check()
  await dialog.getByLabel('Tanggal jatuh tempo').fill('2026-11-02T12:00')
  await dialog.getByRole('button', { name: 'Simpan Draft' }).click()

  await expect(page.getByText(/Draft tersimpan/)).toBeVisible()
  const save = rpcCalls.filter((call) => call.name === 'save_pos_sale_draft_with_ketul').at(-1)
  const payload = save?.payload as { p_payload?: Record<string, unknown> }
  expect(payload.p_payload).toMatchObject({
    customerId: IDS.namedCustomer,
    isTempo: true,
    payments: [],
    fulfillmentMode: 'PICKUP',
  })
  expect(payload.p_payload?.dueDate).toBe('2026-11-02T05:00:00.000Z')
  expect(rpcCalls.some((call) => call.name === 'post_pos_sale_with_ketul')).toBe(false)
})

test('submits a session-scoped Stock Request through save and submit without claiming stock movement', async ({ page }) => {
  const rpcCalls = await installRetailServerMock(page)
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('secret')
  await page.getByRole('button', { name: 'Masuk' }).click()

  await page.getByRole('button', { name: 'Minta Stok' }).click()
  const dialog = page.getByRole('dialog').filter({ hasText: 'Permintaan Stok' })
  await expect(dialog).toBeVisible()
  await dialog.getByLabel(/Produk/).selectOption(`${IDS.product}:${IDS.uom}`)
  await dialog.getByLabel('Jumlah').fill('3')
  await dialog.getByRole('button', { name: 'Kirim permintaan' }).click()

  await expect(page.getByText('Permintaan stok REQ-QA-0001 berhasil dikirim.')).toBeVisible()
  const save = rpcCalls.find((call) => call.name === 'save_stock_request')
  const submit = rpcCalls.find((call) => call.name === 'submit_stock_request')
  expect(save?.payload).toMatchObject({
    p_cashier_session_id: IDS.session,
    p_lines: [{ productId: IDS.product, uomId: IDS.uom, quantity: 3 }],
  })
  expect(submit?.payload).toMatchObject({
    p_document_id: '81000000-0000-4000-8000-000000000001',
    p_master_version: 1,
  })
  expect(rpcCalls.some((call) => call.name.includes('stock_movement'))).toBe(false)
})

test('posts a Goods Receipt from its exact Supplier Order and preserves source quantities', async ({ page }) => {
  const rpcCalls = await installRetailServerMock(page)
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('secret')
  await page.getByRole('button', { name: 'Masuk' }).click()

  await page.getByRole('button', { name: 'Terima Barang' }).click()
  const dialog = page.getByRole('dialog')
  await expect(dialog.getByText('PO-QA-0001')).toBeVisible()
  await dialog.getByRole('button', { name: 'Terima' }).click()
  await dialog.getByLabel('Jumlah aktual diterima').fill('4')
  await dialog.getByRole('button', { name: 'Post & Tambah Stok' }).click()

  await expect(page.getByText('Penerimaan GR-QA-0001 berhasil diposting. Stok sudah diperbarui.')).toBeVisible()
  expect(rpcCalls.find((call) => call.name === 'save_goods_receipt')?.payload).toMatchObject({
    p_cashier_session_id: IDS.session,
    p_supplier_order_id: IDS.supplierOrder,
    p_lines: [{
      supplierOrderLineId: IDS.supplierOrderLine,
      receivedUomId: IDS.uom,
      receivedQty: 4,
      acceptedGoodQty: 4,
      damagedQty: 0,
      rejectedQty: 0,
    }],
  })
  expect(rpcCalls.find((call) => call.name === 'post_goods_receipt')?.payload).toMatchObject({
    p_document_id: IDS.goodsReceipt,
    p_master_version: 1,
  })
})

test('creates a Supplier Return draft for manager approval without directly posting stock', async ({ page }) => {
  const rpcCalls = await installRetailServerMock(page)
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('secret')
  await page.getByRole('button', { name: 'Masuk' }).click()

  await page.getByRole('button', { name: 'Retur Supplier' }).click()
  const dialog = page.getByRole('dialog')
  await expect(dialog.getByText('GR-QA-0001')).toBeVisible()
  await dialog.getByRole('button', { name: 'Pilih' }).click()
  await dialog.getByLabel(/Alasan retur/).fill('Kemasan rusak saat diterima')
  await dialog.getByRole('checkbox').check()
  await dialog.getByLabel('Jumlah retur').fill('2')
  await dialog.getByRole('button', { name: 'Kirim untuk Approval' }).click()

  await expect(page.getByText('Draft PR-QA-0001 dikirim untuk approval manager. Stok belum berubah.')).toBeVisible()
  expect(rpcCalls.find((call) => call.name === 'save_purchase_return_draft')?.payload).toMatchObject({
    p_cashier_session_id: IDS.session,
    p_source_receipt_id: IDS.goodsReceipt,
    p_source_warehouse_id: IDS.warehouse,
    p_return_reason: 'Kemasan rusak saat diterima',
    p_lines: [{
      sourceConditionAllocationId: IDS.receiptAllocation,
      returnUomId: IDS.uom,
      returnQty: 2,
    }],
  })
  expect(rpcCalls.some((call) => call.name === 'post_purchase_return')).toBe(false)
})

test('records a blind Stock Opname count and sends only counted results for Backoffice review', async ({ page }) => {
  const rpcCalls = await installRetailServerMock(page)
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('secret')
  await page.getByRole('button', { name: 'Masuk' }).click()

  await page.getByRole('button', { name: 'Opname' }).click()
  const dialog = page.getByText('Stock Opname').locator('xpath=ancestor::section[1]')
  await expect(dialog.getByText('OPN-QA-0001')).toBeVisible()
  await dialog.getByRole('button', { name: 'Lanjutkan' }).click()
  await dialog.getByLabel('Jumlah fisik (PACK)').fill('7')
  await dialog.getByRole('button', { name: 'Simpan' }).click()
  await expect(dialog.getByText('Ayam Frozen QA berhasil disimpan.')).toBeVisible()
  await dialog.getByRole('button', { name: 'Review hasil (1)' }).click()
  await dialog.getByRole('button', { name: 'Kirim 1 hasil hitung' }).click()

  await expect(page.getByText(/OPN-QA-0001 dikirim: 1 produk dihitung/)).toBeVisible()
  expect(rpcCalls.find((call) => call.name === 'record_stock_opname_count')?.payload).toEqual({
    p_opname_id: IDS.stockOpname,
    p_master_version: 2,
    p_product_id: IDS.product,
    p_physical_qty: 7,
    p_notes: null,
  })
  expect(rpcCalls.find((call) => call.name === 'complete_stock_opname_partial')?.payload).toEqual({
    p_opname_id: IDS.stockOpname,
    p_master_version: 3,
    p_skip_unresolved: false,
  })
})

test('submits a Cash Deposit from selected CLOSED sessions with its allocation snapshot', async ({ page }) => {
  const rpcCalls = await installRetailServerMock(page)
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('secret')
  await page.getByRole('button', { name: 'Masuk' }).click()

  await page.getByRole('button', { name: 'Setor Kas' }).click()
  const dialog = page.getByRole('dialog', { name: 'Buat Setor Kas' })
  await dialog.getByText('SES-QA-CLOSED').locator('xpath=ancestor::label[1]').getByRole('checkbox').check()
  await dialog.getByLabel('Bank / rekening tujuan').fill('BCA Operasional QA')
  await dialog.getByLabel('Nominal aktual yang disetor').fill('150000')
  await dialog.getByLabel(/Saya sudah menghitung kas fisik/).check()
  await dialog.getByRole('button', { name: 'Simpan & Ajukan' }).click()

  await expect(page.getByText(/Setor Kas berhasil diajukan/)).toBeVisible()
  expect(rpcCalls.find((call) => call.name === 'save_cash_deposit_draft')?.payload).toMatchObject({
    p_store_id: IDS.store,
    p_destination_type: 'BANK',
    p_destination_name: 'BCA Operasional QA',
    p_actual_deposit_amount: 150000,
    p_sessions: [{ sessionId: IDS.closedSession, nextSessionFloatReserved: 0 }],
  })
  expect(rpcCalls.find((call) => call.name === 'submit_cash_deposit')?.payload).toMatchObject({
    p_document_id: IDS.cashDeposit,
    p_master_version: 1,
  })
})

test('closes only the active Cashier Session with the entered physical cash snapshot', async ({ page }) => {
  const rpcCalls = await installRetailServerMock(page)
  await page.goto(pwaBaseUrl)
  await page.getByLabel('Email').fill('qa.cashier@example.test')
  await page.getByLabel('Password').fill('secret')
  await page.getByRole('button', { name: 'Masuk' }).click()

  await page.getByRole('button', { name: 'Tutup sesi kasir' }).click()
  const dialog = page.getByRole('dialog', { name: 'Tutup Sesi' })
  await dialog.getByLabel('Kas fisik penutupan').fill('100000')
  await dialog.getByRole('button', { name: 'Konfirmasi Tutup' }).click()

  await expect(page.getByText(/Sesi ditutup\. Expected/)).toBeVisible()
  expect(rpcCalls.find((call) => call.name === 'close_cashier_session')?.payload).toEqual({
    p_cashier_session_id: IDS.session,
    p_master_version: 1,
    p_closing_cash_actual: 100000,
  })
})
