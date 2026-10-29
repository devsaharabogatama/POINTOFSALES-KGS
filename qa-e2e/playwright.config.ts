import { defineConfig } from '@playwright/test'

export default defineConfig({
  testDir: './tests',
  fullyParallel: false,
  workers: 1,
  timeout: 45_000,
  expect: { timeout: 10_000 },
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    headless: true,
    serviceWorkers: 'block',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    launchOptions: {
      executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
    },
  },
  webServer: [
    {
      command: 'node node_modules/next/dist/bin/next start -p 3197',
      cwd: '../backoffice',
      url: 'http://127.0.0.1:3197',
      reuseExistingServer: true,
      timeout: 120_000,
    },
    {
      command: 'node node_modules/vite/bin/vite.js preview --host 127.0.0.1 --port 5197',
      cwd: '../pwa',
      url: 'http://127.0.0.1:5197',
      reuseExistingServer: true,
      timeout: 120_000,
    },
  ],
})
