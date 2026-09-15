param([string]$Profile = 'supabase')

# Compile only with public credentials. No service-role credential is injected.
# Does not rewrite env files or the repository Supabase link, or start a server.
$ErrorActionPreference = 'Stop'
$cloneRef = 'idrufihckscppsyclmsu'
$cloneWorkdir = Join-Path $env:TEMP 'mads-clone-rehearsal'
$marker = Join-Path $cloneWorkdir 'supabase/.temp/project-ref'
if (-not (Test-Path -LiteralPath $marker) -or
    (Get-Content -LiteralPath $marker -Raw).Trim() -ne $cloneRef) {
  throw 'CLONE_ENVIRONMENT_GUARD_FAILED: linked temporary workspace must match authorized clone.'
}
$raw = & supabase.cmd --workdir $cloneWorkdir projects api-keys `
  --project-ref $cloneRef --profile $Profile --output json
if ($LASTEXITCODE -ne 0) { throw 'Unable to retrieve authorized clone API keys.' }
$keys = ConvertFrom-Json -InputObject ($raw -join "`n")
$public = @($keys | Where-Object { $_.name -eq 'anon' } | Select-Object -First 1)
if ($public.Count -ne 1 -or
    [string]::IsNullOrWhiteSpace([string]$public[0].api_key)) {
  throw 'Clone public anon key required; no fallback to another project.'
}
$env:MADS_ENVIRONMENT = 'development'
$env:MADS_SUPABASE_PROJECT_REF = $cloneRef
$env:MADS_BACKOFFICE_SALES_DEVELOPMENT = '1'
$env:NEXT_PUBLIC_SUPABASE_URL = "https://$cloneRef.supabase.co"
$env:NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY = [string]$public[0].api_key
$env:NEXT_PUBLIC_SUPABASE_ANON_KEY = [string]$public[0].api_key
Write-Output "ENVIRONMENT_GUARD=PASS; TARGET_REF=$cloneRef; ACTION=LOCAL_BUILD_ONLY"
Write-Output 'PRODUCTION_AND_EXISTING_STAGING_ACCESS=DENIED; ENV_FILES_AND_REPO_LINK_UNCHANGED'
Push-Location (Join-Path (Split-Path -Parent $PSScriptRoot) 'backoffice')
try {
  # Explicit empty server credential in the Node child prevents dotenv fallback
  # from supplying a privileged key. This is compile evidence, not runtime smoke.
  & node.exe .\scripts\compile-clone-without-server-secret.mjs
  exit $LASTEXITCODE
} finally { Pop-Location }
