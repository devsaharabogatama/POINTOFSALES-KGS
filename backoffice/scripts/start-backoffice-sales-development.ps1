param(
  [ValidateSet('check','dev','build')]
  [string]$Action = 'dev'
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
    if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) {
      continue
    }
    if ($line -notmatch '^\s*([^=]+)=(.*)$') {
      throw "Invalid environment line in $Path"
    }
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

$values = @{}
if (-not (Test-Path -LiteralPath $envPath)) {
  throw 'Create backoffice/.env.backoffice-sales.local from the example and set the exact NEW Development project ref.'
}
$values = Read-EnvFile $envPath

$required = @(
  'MADS_ENVIRONMENT',
  'MADS_SUPABASE_PROJECT_REF'
)
foreach ($name in $required) {
  if (-not $values.ContainsKey($name) -or
      [string]::IsNullOrWhiteSpace([string]$values[$name]) -or
      [string]$values[$name] -match '^replace-with-') {
    throw "Missing Development value: $name"
  }
}

if ($values['MADS_ENVIRONMENT'] -ne 'development') {
  throw 'MADS_ENVIRONMENT must be development.'
}
$expectedDevelopmentRef = [string]$values['MADS_SUPABASE_PROJECT_REF']
if ($expectedDevelopmentRef -eq $productionRef) {
  throw 'Production project reference is forbidden.'
}
if ($expectedDevelopmentRef -eq $existingStagingRef) {
  throw 'The existing staging project reference is forbidden for this isolated build.'
}

$expectedUrl = "https://$expectedDevelopmentRef.supabase.co"
$values['NEXT_PUBLIC_SUPABASE_URL'] = $expectedUrl

$keyNames = @('NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY','SUPABASE_SERVICE_ROLE_KEY')
$missingKeys = @($keyNames | Where-Object {
  -not $values.ContainsKey($_) -or [string]::IsNullOrWhiteSpace([string]$values[$_]) -or
  [string]$values[$_] -match '^replace-with-'
})
if ($missingKeys.Count -gt 0) {
  $supabase = Get-Command 'supabase.cmd' -ErrorAction SilentlyContinue
  if (-not $supabase) {
    throw 'Supabase CLI is required to retrieve Development API keys in memory.'
  }
  $rawKeys = & $supabase.Source projects api-keys --project-ref $expectedDevelopmentRef --output json
  if ($LASTEXITCODE -ne 0) {
    throw 'Unable to obtain API keys for the explicitly selected Development project.'
  }
  $keys = ConvertFrom-Json -InputObject ($rawKeys -join "`n")
  $publishable = @($keys | Where-Object { $_.type -eq 'publishable' } | Select-Object -First 1)
  if ($publishable.Count -eq 0) {
    $publishable = @($keys | Where-Object { $_.name -eq 'anon' } | Select-Object -First 1)
  }
  # The application environment contract is still SUPABASE_SERVICE_ROLE_KEY.
  # Prefer the matching legacy service_role JWT while it is available. The
  # isolated Development gateway currently rejects its new sb_secret key for
  # the PostgREST call chain used by createAdminClient().
  $secret = @($keys | Where-Object { $_.name -eq 'service_role' } | Select-Object -First 1)
  if ($secret.Count -eq 0) {
    $secret = @($keys | Where-Object { $_.type -eq 'secret' } | Select-Object -First 1)
  }
  if ($publishable.Count -ne 1 -or $secret.Count -ne 1) {
    throw 'Development publishable/secret API keys are unavailable.'
  }
  $values['NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY'] = [string]$publishable[0].api_key
  $values['SUPABASE_SERVICE_ROLE_KEY'] = [string]$secret[0].api_key
}

if (-not (Test-Path -LiteralPath $linkedRefPath)) {
  throw 'Supabase CLI link marker is missing.'
}
$linkedRef = (Get-Content -LiteralPath $linkedRefPath -Raw).Trim()
if ($linkedRef -ne $expectedDevelopmentRef) {
  throw 'Supabase CLI is not linked to the allowlisted Development project.'
}

foreach ($entry in $values.GetEnumerator()) {
  [Environment]::SetEnvironmentVariable($entry.Key,[string]$entry.Value,'Process')
}
$env:MADS_BACKOFFICE_SALES_DEVELOPMENT = '1'

Write-Output 'ENVIRONMENT_GUARD=PASS'
Write-Output "TARGET_REF=$expectedDevelopmentRef"
Write-Output 'TARGET=NEW_ISOLATED_DEVELOPMENT_PROJECT'
Write-Output 'PRODUCTION_AND_EXISTING_STAGING_ACCESS=DENIED'

if ($Action -eq 'check') {
  exit 0
}

Push-Location $projectRoot
try {
  if ($Action -eq 'build') {
    & npm.cmd run build
  } else {
    & npm.cmd run dev
  }
  exit $LASTEXITCODE
} finally {
  Pop-Location
}
