import { expect, test } from '@playwright/test'

test('Backoffice exposes login and keeps protected APIs fail-closed', async ({ page, request }) => {
  await page.goto('http://127.0.0.1:3197')
  await expect(page.getByRole('heading', { name: 'Masuk ke backoffice' })).toBeVisible()
  await expect(page.getByLabel('Email')).toBeVisible()
  await expect(page.getByLabel('Password')).toBeVisible()

  for (const path of [
    '/api/me/context',
    '/api/inventory/opening-stock',
    '/api/master/products',
    '/api/finance/operations',
  ]) {
    const response = await request.get(`http://127.0.0.1:3197${path}`)
    expect(response.ok(), `${path} must reject anonymous access`).toBeFalsy()
    expect(response.status(), `${path} must fail closed`).toBeGreaterThanOrEqual(400)
  }
})

test('POS PWA exposes Cashier login without contacting an unapproved database', async ({ page }) => {
  const databaseRequests: string[] = []
  await page.route('https://*.supabase.co/**', async (route) => {
    databaseRequests.push(route.request().url())
    await route.abort('blockedbyclient')
  })
  await page.goto('http://127.0.0.1:5197')
  await expect(page.getByRole('heading', { name: 'Masuk sebagai Kasir' })).toBeVisible()
  await expect(page.getByLabel('Email')).toBeVisible()
  await expect(page.getByLabel('Password')).toBeVisible()
  expect(databaseRequests).toEqual([])
})
