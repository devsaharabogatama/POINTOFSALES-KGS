param(
  [string]$BaseUrl = 'http://localhost:3000'
)

$ErrorActionPreference = 'Stop'

$productionRef = 'nbxjslqojexjfogamnjt'
$existingStagingRef = 'yjxpddwrjdczuqyixqwi'
$projectRoot = Split-Path -Parent $PSScriptRoot
$repositoryRoot = Split-Path -Parent $projectRoot
$envPath = Join-Path $projectRoot '.env.backoffice-sales.local'
$linkedRefPath = Join-Path $repositoryRoot 'supabase/.temp/project-ref'

function Read-EnvFile([string]$Path) {
  $values = @{}
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line -notmatch '^\s*([^=]+)=(.*)$') { throw "Invalid environment line in $Path" }
    $name = $matches[1].Trim()
    $value = $matches[2].Trim()
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
        ($value.StartsWith("'") -and $value.EndsWith("'"))) {
      $value = $value.Substring(1,$value.Length-2)
    }
    $values[$name] = $value
  }
  return $values
}

function Request-Status([string]$Uri) {
  try {
    $response = Invoke-WebRequest -Uri $Uri -Method Get -UseBasicParsing
    return [int]$response.StatusCode
  } catch {
    if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
    throw
  }
}

function Invoke-AuthenticatedGet(
  [string]$Name,
  [string]$Path,
  [scriptblock]$Assert
) {
  $uri = $BaseUrl.TrimEnd('/') + $Path
  try {
    $payload = Invoke-RestMethod -Uri $uri -Method Get -Headers $script:authHeaders
    & $Assert $payload
    $script:results.Add([pscustomobject]@{ Check = $Name; Status = 'PASS'; Details = $Path })
  } catch {
    $script:results.Add([pscustomobject]@{ Check = $Name; Status = 'FAIL'; Details = $_.Exception.Message })
  }
}

if (-not (Test-Path -LiteralPath $envPath)) {
  throw 'Development environment file is missing.'
}
$values = Read-EnvFile $envPath
$developmentRef = [string]$values['MADS_SUPABASE_PROJECT_REF']
if ($values['MADS_ENVIRONMENT'] -ne 'development' -or
    [string]::IsNullOrWhiteSpace($developmentRef) -or
    $developmentRef -in @($productionRef,$existingStagingRef)) {
  throw 'ENVIRONMENT_GUARD_FAILED: only the isolated Development project is allowed.'
}
if (-not (Test-Path -LiteralPath $linkedRefPath) -or
    (Get-Content -LiteralPath $linkedRefPath -Raw).Trim() -ne $developmentRef) {
  throw 'ENVIRONMENT_GUARD_FAILED: Supabase CLI link does not match Development.'
}

$publishableKey = [string]$values['NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY']
if ([string]::IsNullOrWhiteSpace($publishableKey) -or $publishableKey -match '^replace-with-') {
  $supabase = Get-Command 'supabase.cmd' -ErrorAction SilentlyContinue
  if (-not $supabase) { throw 'Supabase CLI is required to retrieve the Development publishable key.' }
  $rawKeys = & $supabase.Source projects api-keys --project-ref $developmentRef --output json
  if ($LASTEXITCODE -ne 0) { throw 'Unable to obtain Development API keys.' }
  $keys = ConvertFrom-Json -InputObject ($rawKeys -join "`n")
  $candidate = @($keys | Where-Object { $_.type -eq 'publishable' } | Select-Object -First 1)
  if ($candidate.Count -eq 0) {
    $candidate = @($keys | Where-Object { $_.name -eq 'anon' } | Select-Object -First 1)
  }
  if ($candidate.Count -ne 1) { throw 'Development publishable key is unavailable.' }
  $publishableKey = [string]$candidate[0].api_key
}

$healthUri = $BaseUrl.TrimEnd('/') + '/api/me/context'
$unauthenticatedStatus = Request-Status $healthUri
if ($unauthenticatedStatus -ne 401) {
  throw "AUTH_BOUNDARY_FAILED: unauthenticated request returned HTTP $unauthenticatedStatus."
}

$email = Read-Host 'Development smoke email'
$securePassword = Read-Host 'Development smoke password' -AsSecureString
$passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
try {
  $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
  $authUri = "https://$developmentRef.supabase.co/auth/v1/token?grant_type=password"
  $session = Invoke-RestMethod -Uri $authUri -Method Post -Headers @{ apikey = $publishableKey } `
    -ContentType 'application/json' -Body (@{ email = $email; password = $password } | ConvertTo-Json)
} finally {
  if ($passwordPointer -ne [IntPtr]::Zero) {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
  }
  $password = $null
  $securePassword = $null
}
if ([string]::IsNullOrWhiteSpace([string]$session.access_token)) {
  throw 'AUTHENTICATED_SMOKE_LOGIN_FAILED'
}

$script:authHeaders = @{ Authorization = "Bearer $($session.access_token)" }
$script:results = [System.Collections.Generic.List[object]]::new()
$script:results.Add([pscustomobject]@{
  Check = 'environment_and_unauthenticated_boundary'; Status = 'PASS'
  Details = "Development $developmentRef; unauthenticated HTTP 401"
})

Invoke-AuthenticatedGet 'active_company_context' '/api/me/context' {
  param($payload)
  if (-not $payload.profile -or [string]::IsNullOrWhiteSpace([string]$payload.activeCompanyId)) {
    throw 'Active Company context is missing.'
  }
}
Invoke-AuthenticatedGet 'backoffice_sales_order_read' '/api/sales/backoffice-orders?dateBasis=ORDER_DATE' {
  param($payload)
  if ([string]::IsNullOrWhiteSpace([string]$payload.companyId)) { throw 'Company-scoped SO response is missing.' }
}
Invoke-AuthenticatedGet 'backoffice_delivery_read' '/api/inventory/backoffice-delivery-orders' {
  param($payload)
  if ([string]::IsNullOrWhiteSpace([string]$payload.companyId)) { throw 'Company-scoped DO response is missing.' }
}
Invoke-AuthenticatedGet 'backoffice_invoice_read' '/api/sales/backoffice-invoices' {
  param($payload)
  if ([string]::IsNullOrWhiteSpace([string]$payload.companyId)) { throw 'Company-scoped Invoice response is missing.' }
}
$asOf = Get-Date -Format 'yyyy-MM-dd'
Invoke-AuthenticatedGet 'delivered_not_invoiced_report' "/api/finance/operations?report=DELIVERED_NOT_INVOICED&asOf=$asOf" {
  param($payload)
  if (-not $payload.data -or $payload.data.reportVersion -ne 'DNI_AS_OF_V1' -or
      $payload.data.financialStatementIncluded -ne $false) {
    throw 'Canonical Delivered Not Invoiced response is invalid.'
  }
}
Invoke-AuthenticatedGet 'data_exchange_catalog' '/api/data-exchange/catalog' {
  param($payload)
  if (-not $payload.data -or -not $payload.data.items) { throw 'Authorized Data Exchange catalog is missing.' }
  $dni = @($payload.data.items | Where-Object { $_.typeKey -eq 'DELIVERED_NOT_INVOICED' })
  if ($dni.Count -ne 1) { throw 'Delivered Not Invoiced export catalog entry is missing or duplicated.' }
}

$script:results | Format-Table -AutoSize
$failed = @($script:results | Where-Object { $_.Status -ne 'PASS' })
if ($failed.Count -gt 0) {
  throw "AUTHENTICATED_SMOKE_FAILED: $($failed.Count) check(s) failed."
}
Write-Output 'AUTHENTICATED_SMOKE=PASS'
Write-Output 'MUTATIONS=NONE'
Write-Output 'PRODUCTION_AND_EXISTING_STAGING_ACCESS=DENIED'
