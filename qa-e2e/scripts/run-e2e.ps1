$ErrorActionPreference = 'Stop'

$qaRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repoRoot = (Resolve-Path (Join-Path $qaRoot '..')).Path
$backofficeRoot = Join-Path $repoRoot 'backoffice'
$pwaRoot = Join-Path $repoRoot 'pwa'
$started = @()

function Assert-PortFree([int]$Port) {
  $listener = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
  if ($listener) {
    throw "Port $Port sedang dipakai process $($listener.OwningProcess). Hentikan process tersebut sebelum menjalankan E2E."
  }
}

function Wait-Http([string]$Url) {
  for ($attempt = 0; $attempt -lt 60; $attempt += 1) {
    try {
      $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2
      if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 500) {
        return
      }
    } catch {
      Start-Sleep -Milliseconds 500
    }
  }
  throw "Server E2E tidak siap: $Url"
}

try {
  if (-not (Test-Path (Join-Path $backofficeRoot '.next\BUILD_ID'))) {
    throw 'Build Backoffice belum ada. Jalankan npm.cmd run build di folder backoffice.'
  }
  if (-not (Test-Path (Join-Path $pwaRoot 'dist\index.html'))) {
    throw 'Build POS PWA belum ada. Jalankan npm.cmd run build di folder pwa.'
  }

  Assert-PortFree 3197
  Assert-PortFree 5197

  $backoffice = Start-Process -FilePath 'node.exe' `
    -ArgumentList @('node_modules/next/dist/bin/next', 'start', '-p', '3197') `
    -WorkingDirectory $backofficeRoot -WindowStyle Hidden -PassThru
  $started += $backoffice

  $pwa = Start-Process -FilePath 'node.exe' `
    -ArgumentList @('node_modules/vite/bin/vite.js', 'preview', '--host', '127.0.0.1', '--port', '5197') `
    -WorkingDirectory $pwaRoot -WindowStyle Hidden -PassThru
  $started += $pwa

  Wait-Http 'http://127.0.0.1:3197'
  Wait-Http 'http://127.0.0.1:5197'

  Push-Location $qaRoot
  try {
    & node.exe 'node_modules/@playwright/test/cli.js' test '--reporter=line'
    if ($LASTEXITCODE -ne 0) {
      exit $LASTEXITCODE
    }
  } finally {
    Pop-Location
  }
} finally {
  foreach ($process in $started) {
    if ($process -and -not $process.HasExited) {
      Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
  }
}
