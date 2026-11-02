$ErrorActionPreference = 'Stop'

$qaRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repoRoot = (Resolve-Path (Join-Path $qaRoot '..')).Path
$pwaRoot = Join-Path $repoRoot 'pwa'

Write-Host 'Building current POS PWA source...'
Push-Location $pwaRoot
try {
  & npm.cmd run build
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
  Pop-Location
}

Write-Host 'Running comprehensive mocked POS browser E2E and runtime contracts...'
Push-Location $qaRoot
try {
  & node.exe 'node_modules/@playwright/test/cli.js' test `
    '--config=playwright.pos.config.ts'
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
  Pop-Location
}

Write-Host ''
Write-Host 'POS mocked E2E finished. HTML report:'
Write-Host (Join-Path $qaRoot 'playwright-report\pos\index.html')
