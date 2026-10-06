[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$CaptureDirectory,
  [int]$Port=3186
)
$ErrorActionPreference='Stop'
$scriptDirectory=if($PSScriptRoot){$PSScriptRoot}else{Join-Path (Get-Location) 'scripts'}
$root=Split-Path -Parent $scriptDirectory
$workdir=Join-Path $env:TEMP 'mads-invoice-staging-20261005'
$target='yjxpddwrjdczuqyixqwi'
$projectRef=(Get-Content -LiteralPath (Join-Path $workdir 'supabase/.temp/project-ref') -Raw).Trim()
if($projectRef -ne $target){throw 'AUTHORIZED_STAGING_TARGET_REQUIRED'}
if($Port -lt 1024 -or $Port -gt 65535){throw 'LOCAL_PORT_INVALID'}
$output=Join-Path $CaptureDirectory 'invoice-revision-authenticated-api-smoke.json'
$previous=@{}
foreach($key in @('SUPABASE_PROFILE','PGHOST','PGPORT','PGUSER','PGPASSWORD','PGDATABASE',
  'NEXT_PUBLIC_SUPABASE_URL','NEXT_PUBLIC_SUPABASE_ANON_KEY','NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY',
  'SUPABASE_SERVICE_ROLE_KEY','INVOICE_SMOKE_SERVER_BASE')) {
  $previous[$key]=[Environment]::GetEnvironmentVariable($key,'Process')
}
$process=$null
$stdout=Join-Path $env:TEMP 'mads-invoice-revision-smoke-server.out.log'
$stderr=Join-Path $env:TEMP 'mads-invoice-revision-smoke-server.err.log'
try {
  $env:SUPABASE_PROFILE='supabase'
  $raw=& supabase.cmd db dump --workdir $workdir --linked --dry-run
  if($LASTEXITCODE -ne 0){throw 'STAGING_LOGIN_PARAMETERS_UNAVAILABLE'}
  $found=@{}
  foreach($line in $raw) {
    if($line -match '^export (PGHOST|PGPORT|PGUSER|PGPASSWORD|PGDATABASE)="([^"]*)"$') {
      $found[$Matches[1]]=$Matches[2]
    }
  }
  if($found.Count -ne 5){throw 'UNRECOGNIZED_CLI_CONNECTION_FORMAT'}
  if(!$found.PGUSER.EndsWith('.'+$target) -or $found.PGHOST -ne 'aws-0-ap-southeast-1.pooler.supabase.com'){
    throw 'NON_STAGING_CONNECTION_REJECTED'
  }
  foreach($key in $found.Keys){[Environment]::SetEnvironmentVariable($key,$found[$key],'Process')}

  $keysRaw=& supabase.cmd projects api-keys --project-ref $target --output json
  if($LASTEXITCODE -ne 0){throw 'STAGING_API_KEYS_UNAVAILABLE'}
  $keys=$keysRaw | ConvertFrom-Json
  $publishable=$keys | Where-Object { $_.type -eq 'publishable' -or $_.name -eq 'anon' } | Select-Object -First 1
  $service=$keys | Where-Object { $_.name -eq 'service_role' } | Select-Object -First 1
  if(!$publishable.api_key -or !$service.api_key){throw 'STAGING_API_KEY_SHAPE_INVALID'}
  $env:NEXT_PUBLIC_SUPABASE_URL="https://$target.supabase.co"
  $env:NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=$publishable.api_key
  $env:NEXT_PUBLIC_SUPABASE_ANON_KEY=$publishable.api_key
  $env:SUPABASE_SERVICE_ROLE_KEY=$service.api_key
  $env:INVOICE_SMOKE_SERVER_BASE="http://127.0.0.1:$Port"

  Remove-Item -LiteralPath $stdout,$stderr -ErrorAction SilentlyContinue
  $process=Start-Process -FilePath 'node.exe' -ArgumentList @('node_modules/next/dist/bin/next','start','-p',[string]$Port) `
    -WorkingDirectory (Join-Path $root 'backoffice') -WindowStyle Hidden `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
  $ready=$false
  for($attempt=0;$attempt -lt 30;$attempt++) {
    Start-Sleep -Milliseconds 500
    if($process.HasExited){break}
    try {
      $response=Invoke-WebRequest -Uri "http://127.0.0.1:$Port" -UseBasicParsing -TimeoutSec 2
      if([int]$response.StatusCode -ge 200){$ready=$true;break}
    } catch {}
  }
  if(!$ready){
    $tail=(Get-Content -LiteralPath $stderr -Tail 30 -ErrorAction SilentlyContinue) -join "`n"
    throw "LOCAL_STAGING_CLIENT_NOT_READY: $tail"
  }
  & node (Join-Path $scriptDirectory 'run-invoice-revision-authenticated-staging-smoke.mjs') $output
  if($LASTEXITCODE -ne 0){throw 'AUTHENTICATED_STAGING_API_SMOKE_FAILED'}
} finally {
  if($process -and !$process.HasExited){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue}
  foreach($key in $previous.Keys){[Environment]::SetEnvironmentVariable($key,$previous[$key],'Process')}
  Remove-Variable raw,found,keysRaw,keys,publishable,service -ErrorAction SilentlyContinue
}
