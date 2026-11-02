import { expect, test } from '@playwright/test'
import { readFile } from 'node:fs/promises'

const root = new URL('../../', import.meta.url)
const read = (path: string) => readFile(new URL(path, root), 'utf8')

test('every declared Backoffice navigation view has an active rendering branch', async () => {
  const [catalog, page] = await Promise.all([
    read('backoffice/src/lib/navigation-catalog.ts'),
    read('backoffice/src/app/page.tsx'),
  ])
  const viewBlock = catalog.match(/const itemDefinitions: ItemDefinition\[\] = \[([\s\S]*?)\n\]/)?.[1]
  expect(viewBlock, 'itemDefinitions must remain discoverable').toBeTruthy()
  const ids = [...(viewBlock ?? '').matchAll(/\{ id: ['"]([^'"]+)['"]/g)].map((match) => match[1])
  expect(ids.length).toBeGreaterThan(30)
  const missing = ids.filter((id) => !page.includes(`activeView === "${id}"`))
  expect(missing, `views without a render branch: ${missing.join(', ')}`).toEqual([])
})

test('Retail checkout keeps canonical Draft, price, direct posting, payment and offline boundaries', async () => {
  const [app, runtime, ketulMigration, ketulReadinessMigration] = await Promise.all([
    read('pwa/src/App.tsx'),
    read('pwa/src/lib/pos.ts'),
    read('supabase/migrations/20261031110000_pos_ketul_customer_intake_offset.sql'),
    read('supabase/migrations/20261101120000_pos_ketul_kgs_readiness_forward_fix.sql'),
  ])
  for (const rpc of [
    'save_pos_sale_draft_with_ketul',
    'preview_pos_sale_prices',
    'post_pos_sale_with_ketul',
    'get_pos_payment_method_references',
    'get_pos_stock_availability',
    'get_pos_ketul_readiness',
  ]) expect(runtime).toContain(rpc)
  expect(ketulMigration).toContain('public.save_pos_sale_draft_with_pricelist(v_payload)')
  expect(ketulMigration).toContain('public.post_pos_sale_with_pricelist(')
  expect(ketulReadinessMigration).toContain('public.private_active_company_id()')
  expect(ketulReadinessMigration).toContain("'KETUL_PAYABLE_MAPPING_NOT_READY'")
  expect(ketulReadinessMigration).toContain("method.method_type='KETUL_OFFSET'")
  const checkout = app.match(/async function postSaleWithNegativeReason[\s\S]*?\n  function resetSale/)?.[0]
  expect(checkout, 'active Retail checkout function must remain discoverable').toBeTruthy()
  expect(checkout).toContain('postSale(')
  expect(app).toContain('catalog.ketulEnabled && !isBackofficeCutoverDraft')
  expect(app).toContain('setKetulIntakeLines(isBackofficeCutover ? [] : nextKetulLines)')
  expect(checkout).not.toContain('confirmSalesOrder(')
  expect(checkout).toContain("fulfillmentMode === 'DELIVERY'")
  expect(checkout).toContain('loadSalesDeliveryDocument')
  expect(app).toContain('PAYMENT_LEG_TOTAL_MISMATCH')
  expect(app).toContain('NEGATIVE_STOCK_REASON_REQUIRED')
  expect(app).toContain('Simpan Offline')
  expect(app).toContain('BELUM TERSINKRON')
  expect(app).toContain('Selesaikan Transaksi')
})

test('Backoffice Sales Order remains on its separate canonical runtime', async () => {
  const migration = await read('supabase/migrations/20260908120000_backoffice_sales_order_runtime.sql')
  expect(migration).toContain('CREATE FUNCTION public.confirm_backoffice_sales_order')
  expect(migration).toContain('private.transition_backoffice_sales_order')
  expect(migration).toContain('public.backoffice_sales_orders')
  expect(migration).not.toContain('post_pos_sale_with_pricelist')
})

test('direct Retail post bridge is scoped away from Backoffice and reserved Orders', async () => {
  const migration = await read('supabase/migrations/20261030120000_pos_retail_direct_post_order_runtime_bridge.sql')
  expect(migration).toContain("OLD.sales_origin NOT IN('POS','BACKOFFICE_CUTOVER')")
  expect(migration).toContain('RETURN NEW;')
  expect(migration).toContain('RETAIL_DIRECT_POST_CUTOVER_ADOPTION_REQUIRED')
  expect(migration).toContain('private.sales_process_retail_identity_is_valid(')
  expect(migration).toContain("OLD.sales_process_mode<>'RETAIL_CONFIRM_INVOICE'")
  expect(migration).toContain("v_active_mode IS DISTINCT FROM 'RETAIL_CONFIRM_INVOICE'")
  expect(migration).toContain("OLD.order_runtime_status IN('DRAFT_INPUT','SCHEDULED')")
  expect(migration).toContain('OLD.reservation_version<>0')
  expect(migration).toContain('public.sales_stock_reservations')
  expect(migration).toContain("NEW.order_runtime_status:='LEGACY_POSTED'")
  expect(migration).not.toContain('public.backoffice_sales_orders')
  expect(migration).not.toContain('public.backoffice_sales_order_lines')
})

test('Retail PWA keeps every approved operational workspace wired to canonical RPCs', async () => {
  const [app, runtime] = await Promise.all([
    read('pwa/src/App.tsx'),
    read('pwa/src/lib/pos.ts'),
  ])
  for (const label of [
    'Return',
    'Expense',
    'Minta Stok',
    'Terima Barang',
    'Retur Supplier',
    'Opname',
    'Setor Kas',
    'Tutup sesi kasir',
  ]) expect(app).toContain(label)
  for (const rpc of [
    'close_cashier_session',
    'get_pos_returnable_sales',
    'submit_pos_sales_return_with_delivery_fee',
    'save_expense_draft',
    'submit_expense_request',
    'post_pos_expense',
    'get_pos_stock_request_workspace',
    'save_stock_request',
    'submit_stock_request',
    'get_pos_goods_receipt_supplier_orders',
    'save_goods_receipt',
    'post_goods_receipt',
    'get_pos_purchase_return_workspace',
    'save_purchase_return_draft',
    'get_pos_stock_opname_workspace',
    'save_stock_opname_session',
    'complete_stock_opname_partial',
    'list_cash_deposit_eligible_sessions',
    'save_cash_deposit_draft',
    'submit_cash_deposit',
  ]) expect(runtime, `Retail runtime must retain ${rpc}`).toContain(rpc)
})

test('direct Sales Return finalization is scoped to POS Retail and preserves Backoffice approval', async () => {
  const [runtime, migration, approvalRoute] = await Promise.all([
    read('pwa/src/lib/pos.ts'),
    read('supabase/migrations/20261102100000_pos_retail_direct_sales_return_refund.sql'),
    read('backoffice/src/app/api/sales/returns/[id]/post/route.ts'),
  ])
  expect(runtime).toContain('submit_pos_sales_return_with_delivery_fee')
  expect(migration).toContain("setting.active_mode='RETAIL_CONFIRM_INVOICE'")
  expect(migration).toContain("v_sale.sales_origin='POS'")
  expect(migration).toContain("v_sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'")
  expect(migration).toContain("'approvalMode','REQUIRED'")
  expect(migration).toContain('public.save_sales_return_draft_with_delivery_fee(')
  expect(migration).toContain('private.acp5h_post_sales_return_core(')
  expect(migration).toContain('POS_SALES_RETURN_CHANGED_RETRY')
  expect(approvalRoute).toContain('post_sales_return')
  expect(approvalRoute).not.toContain('submit_pos_sales_return_with_delivery_fee')
})

test('Sales Return Transfer metadata is optional without weakening settlement boundaries', async () => {
  const [ui, migration, postflight, behavior] = await Promise.all([
    read('pwa/src/SalesReturnModal.tsx'),
    read('supabase/migrations/20261102110000_pos_sales_return_optional_transfer_metadata.sql'),
    read('supabase/diagnostics/pos_sales_return_optional_transfer_metadata_postflight.sql'),
    read('supabase/tests/pos_sales_return_optional_transfer_metadata_behavior.sql'),
  ])
  expect(ui).toContain('Tujuan transfer (opsional)')
  expect(ui).toContain('Nomor referensi (opsional)')
  expect(ui).not.toContain('Tujuan transfer dan nomor referensi wajib diisi.')
  expect(migration).toContain('DROP CONSTRAINT sales_return_refund_transfer_contract')
  expect(migration).toContain(
    "v_destination_new text:='NULLIF(btrim(v_refund->>''transferDestination''),'''') END,'",
  )
  expect(migration).toContain(
    "v_reference_new text:='NULLIF(btrim(v_refund->>''transferReference''),'''') END,'",
  )
  expect(migration).toContain('odr6d_returnable_sales_detail_quantity')
  expect(postflight).toContain('pos_return_optional_transfer_postflight_core_contract')
  expect(behavior).toContain('blankMetadataNormalized')
  expect(behavior).toContain('populatedMetadataPreserved')
  expect(behavior).toContain('financeEvent')
})

test('Opening Stock remains a guarded Backoffice workflow rather than a generic import', async () => {
  const [catalog, component, collectionRoute, postRoute] = await Promise.all([
    read('backoffice/src/lib/navigation-catalog.ts'),
    read('backoffice/src/components/OpeningStockView.tsx'),
    read('backoffice/src/app/api/inventory/opening-stock/route.ts'),
    read('backoffice/src/app/api/inventory/opening-stock/[id]/post/route.ts'),
  ])
  expect(catalog).toContain("id: 'opening-stock'")
  expect(component).toContain('HPP per Base UOM')
  expect(component).toContain('Otomatis dari HPP Product')
  expect(component).toContain('OPENING_STOCK_MOVEMENT_ALREADY_EXISTS')
  expect(collectionRoute).toContain(".select('id,cogs')")
  expect(collectionRoute).toContain('default_unit_cost')
  expect(collectionRoute).toContain("'inventory.opening_stock', 'CREATE_DRAFT'")
  expect(collectionRoute).toContain("'save_opening_stock_document'")
  expect(postRoute).toContain("'inventory.opening_stock', 'POST'")
  expect(postRoute).toContain("'post_opening_stock'")
})

test('Finance exposes unresolved mapping as a manual worklist with a prefilled rule editor', async () => {
  const [component, completeness] = await Promise.all([
    read('backoffice/src/components/FinanceMasterView.tsx'),
    read('backoffice/src/lib/finance-mapping-completeness.ts'),
  ])
  expect(component).toContain('Mapping yang perlu dilengkapi')
  expect(component).toContain("setCoverageFilter(value)")
  expect(component).toContain("openRuleEditor({ categoryId: item.category_id, accountFunctionKey: item.account_function_key })")
  expect(component).toContain('Finance hanya perlu memilih akun dan tanggal efektif.')
  expect(component).toContain('tidak mengubah jurnal yang sudah diposting')
  expect(completeness).toContain("filter === 'UNRESOLVED' && !isFinanceMappingReady(row)")
  expect(completeness).toContain("row.requirement === filter")
})

test('Finance Opening Balance is direct-entry and keeps GL, AR, AP and Inventory boundaries explicit', async () => {
  const [operations, component, route, migration] = await Promise.all([
    read('backoffice/src/components/FinanceOperationsView.tsx'),
    read('backoffice/src/components/OpeningBalanceView.tsx'),
    read('backoffice/src/app/api/finance/opening-balances/route.ts'),
    read('supabase/migrations/20261029100000_opening_balance_direct_entry.sql'),
  ])
  expect(operations).toContain('["opening", "Saldo Awal"')
  expect(operations).toContain('<OpeningBalanceView')
  expect(component).toContain('Saldo Awal langsung dari aplikasi')
  expect(component).toContain('Persediaan tidak diinput di sini.')
  expect(component).toContain('+ Piutang Customer')
  expect(component).toContain('+ Utang Supplier')
  expect(component).toContain('Histori invoice lama tidak perlu dibuat ulang.')
  expect(component).not.toContain('Nomor invoice lama')
  expect(route).toContain('sourceDocumentNo: null')
  for (const action of ['SAVE_DRAFT', 'SUBMIT', 'POST', 'CANCEL']) expect(route).toContain(action)
  for (const rpc of [
    'save_opening_balance_draft',
    'submit_opening_balance',
    'post_opening_balance',
    'cancel_opening_balance',
  ]) expect(route).toContain(rpc)
  expect(migration).toContain("'OPENING_BALANCE',")
  expect(migration).toContain('OPENING_BALANCE_CONTROL_ACCOUNT_REQUIRES_DETAIL')
  expect(migration).toContain('OPENING_BALANCE_SELF_APPROVAL_FORBIDDEN')
  expect(migration).toContain("line_type IN('GL','RECEIVABLE','PAYABLE')")
  expect(migration).toContain('OPENING_BALANCE_PARTY_DUPLICATE')
})
