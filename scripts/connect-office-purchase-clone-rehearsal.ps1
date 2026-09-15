[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$targetRef = 'idrufihckscppsyclmsu'
$developmentRef = 'fkywtxucmyjvpwdiqpix'
$productionRef = 'nbxjslqojexjfogamnjt'
$legacyStagingRef = 'yjxpddwrjdczuqyixqwi'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$repositoryRefPath = Join-Path $repositoryRoot 'supabase/.temp/project-ref'
$isolatedWorkdir = Join-Path $env:TEMP 'mads-clone-rehearsal'
$isolatedRefPath = Join-Path $isolatedWorkdir 'supabase/.temp/project-ref'

$supabase = Get-Command 'supabase.cmd' -ErrorAction Stop

function Assert-LastExitCode {
  param([Parameter(Mandatory = $true)][string]$Operation)
  if ($LASTEXITCODE -ne 0) {
    throw "$Operation failed with exit code $LASTEXITCODE"
  }
}

function Read-TrimmedRef {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }
  return (Get-Content -LiteralPath $Path -Raw).Trim()
}

$repositoryRefBefore = Read-TrimmedRef -Path $repositoryRefPath
if ($repositoryRefBefore -and $repositoryRefBefore -ne $developmentRef) {
  throw "REPOSITORY_LINK_GUARD_FAILED: expected $developmentRef, found $repositoryRefBefore"
}

$secureToken = Read-Host 'Masukkan Personal Access Token akun clone' -AsSecureString
$tokenPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
$previousAccessToken = $env:SUPABASE_ACCESS_TOKEN
$previousSupabaseProfile = $env:SUPABASE_PROFILE

try {
  $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPointer)
  $env:SUPABASE_ACCESS_TOKEN = $plainToken
  # CLI 2.107.0 misreads ~/.supabase/profile when it contains a named token.
  # Force the built-in Supabase platform while the explicit process-only PAT
  # remains the authentication authority.
  $env:SUPABASE_PROFILE = 'supabase'

  $projectJson = & $supabase.Source projects list --output json
  Assert-LastExitCode -Operation 'Supabase rehearsal project inventory'
  $projects = @($projectJson | ConvertFrom-Json)
  if (-not ($projects | Where-Object { $_.ref -eq $targetRef })) {
    throw "TARGET_PROJECT_NOT_VISIBLE: $targetRef"
  }

  if (-not (Test-Path -LiteralPath $isolatedWorkdir)) {
    New-Item -ItemType Directory -Path $isolatedWorkdir | Out-Null
  }
  if (-not (Test-Path -LiteralPath (Join-Path $isolatedWorkdir 'supabase/config.toml'))) {
    & $supabase.Source init --workdir $isolatedWorkdir --yes
    Assert-LastExitCode -Operation 'Isolated Supabase workdir initialization'
  }

  & $supabase.Source --workdir $isolatedWorkdir link --project-ref $targetRef
  Assert-LastExitCode -Operation 'Isolated rehearsal project link'

  $isolatedRef = Read-TrimmedRef -Path $isolatedRefPath
  if ($isolatedRef -ne $targetRef) {
    throw "ISOLATED_LINK_GUARD_FAILED: expected $targetRef, found $isolatedRef"
  }
  if (@($productionRef,$developmentRef,$legacyStagingRef) -contains $isolatedRef) {
    throw "FORBIDDEN_TARGET_REF: $isolatedRef"
  }

  $probeSql = @"
select current_database() database_name,
       current_user database_user,
       inet_server_addr() server_address,
       inet_server_port() server_port,
       (select count(*) from public.sales_headers) sales_headers,
       (select count(*) from public.sales_details) sales_details,
       (select count(*) from private.kgs_schema_migrations
        where version between '20260908100000' and '20260914180000') candidate_ledger_rows;
"@

  $probeOutput = & $supabase.Source --workdir $isolatedWorkdir db query `
    --linked $probeSql --output json
  Assert-LastExitCode -Operation 'Clone read-only database probe'

  $repositoryRefAfter = Read-TrimmedRef -Path $repositoryRefPath
  if ($repositoryRefAfter -ne $repositoryRefBefore) {
    throw "REPOSITORY_LINK_CHANGED: before=$repositoryRefBefore after=$repositoryRefAfter"
  }

  Write-Output 'ENVIRONMENT_GUARD=PASS'
  Write-Output "TARGET_REF=$targetRef"
  Write-Output "ISOLATED_WORKDIR=$isolatedWorkdir"
  Write-Output "REPOSITORY_REF=$repositoryRefAfter"
  Write-Output 'DATABASE_PROBE:'
  Write-Output $probeOutput
}
finally {
  if ($null -eq $previousAccessToken) {
    Remove-Item Env:SUPABASE_ACCESS_TOKEN -ErrorAction SilentlyContinue
  }
  else {
    $env:SUPABASE_ACCESS_TOKEN = $previousAccessToken
  }
  if ($null -eq $previousSupabaseProfile) {
    Remove-Item Env:SUPABASE_PROFILE -ErrorAction SilentlyContinue
  }
  else {
    $env:SUPABASE_PROFILE = $previousSupabaseProfile
  }
  if ($tokenPointer -ne [IntPtr]::Zero) {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPointer)
  }
  Remove-Variable -Name @(
    'plainToken','secureToken','tokenPointer','previousAccessToken',
    'previousSupabaseProfile'
  ) -ErrorAction SilentlyContinue
}
