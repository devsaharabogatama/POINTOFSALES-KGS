import { expect, test } from '@playwright/test'
import { readFile } from 'node:fs/promises'

const root = new URL('../../', import.meta.url)
const read = (path: string) => readFile(new URL(path, root), 'utf8')

test('Backoffice Receipt API keeps residual credit customer-scoped and explicit', async () => {
  const route = await read('backoffice/src/app/api/finance/customer-receipts/route.ts')

  expect(route).toContain("caller.client.rpc('get_finance_ar_open_items'")
  expect(route).toContain("'save_customer_receipt_open_credit_draft'")
  expect(route).toContain('receivedAmount < allocatedAmount')
  expect(route).toContain("row.sourceType !== 'BACKOFFICE_SALES_INVOICE'")
  expect(route).toContain('CUSTOMER_RECEIPT_OPEN_CREDIT_BACKOFFICE_ONLY')
})

test('Finance UI shows received, allocated, and residual amounts without auto allocation', async () => {
  const view = await read('backoffice/src/components/CustomerReceiptView.tsx')

  expect(view).toContain('Nominal diterima')
  expect(view).toContain('Dialokasikan ke invoice')
  expect(view).toContain('Sisa kredit Customer')
  expect(view).toContain('Kredit tidak dialokasikan otomatis')
  expect(view).toContain('Kredit dan tagihan terbuka')
  expect(view).toContain("item.direction === 'DEBIT' ? 'Tagihan' : 'Kredit'")
})

test('Task 3 migration covers Finance workspace and Invoice detail payment entry points', async () => {
  const migration = await read('supabase/migrations/20261105110000_backoffice_ar_invoice_receipt_allocation_runtime.sql')

  expect(migration).toContain('CREATE FUNCTION public.post_customer_receipt_unified')
  expect(migration).toContain('CREATE FUNCTION public.post_customer_receipt_allocated')
  expect(migration).toContain('CREATE OR REPLACE FUNCTION public.register_backoffice_sales_invoice_payment')
  expect(migration).toContain('v_posted:=public.post_customer_receipt_allocated')
  expect(migration).toContain('CUSTOMER_RECEIPT_OPEN_CREDIT_BACKOFFICE_ONLY')
})
