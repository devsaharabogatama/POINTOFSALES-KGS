[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$scriptDirectory=if($PSScriptRoot){$PSScriptRoot}else{Join-Path (Get-Location) 'scripts'}
$w=Join-Path $env:TEMP 'mads-invoice-staging-20261005'
$target='yjxpddwrjdczuqyixqwi'
$marker=Join-Path $w 'supabase/.temp/project-ref'
if(!(Test-Path -LiteralPath $marker) -or (Get-Content -LiteralPath $marker -Raw).Trim() -ne $target){throw 'STAGING_LINK_REQUIRED'}
$previous=@{}
foreach($key in @('SUPABASE_PROFILE','PGHOST','PGPORT','PGUSER','PGPASSWORD','PGDATABASE','NODE_USE_SYSTEM_CA','NODE_EXTRA_CA_CERTS')){$previous[$key]=[Environment]::GetEnvironmentVariable($key,'Process')}
try{
  $env:SUPABASE_PROFILE='supabase'
  $env:NODE_USE_SYSTEM_CA='1'
  $caBundle=Join-Path $w 'windows-ca-bundle.pem'
  $pem=New-Object System.Collections.Generic.List[string]
  foreach($location in @([System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser,[System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)){
    foreach($name in @([System.Security.Cryptography.X509Certificates.StoreName]::Root,[System.Security.Cryptography.X509Certificates.StoreName]::CertificateAuthority)){
      $store=New-Object System.Security.Cryptography.X509Certificates.X509Store($name,$location)
      try{
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
        foreach($certificate in $store.Certificates){
          $base64=[Convert]::ToBase64String($certificate.RawData,[Base64FormattingOptions]::InsertLineBreaks)
          $pem.Add("-----BEGIN CERTIFICATE-----`r`n$base64`r`n-----END CERTIFICATE-----")
        }
      } finally {$store.Close()}
    }
  }
  [IO.File]::WriteAllText($caBundle,($pem -join "`r`n"),[Text.Encoding]::ASCII)
  $env:NODE_EXTRA_CA_CERTS=$caBundle
  $raw=& supabase.cmd db dump --workdir $w --linked --dry-run
  if($LASTEXITCODE -ne 0){throw 'STAGING_LOGIN_PARAMETERS_UNAVAILABLE'}
  $found=@{}
  foreach($line in $raw){if($line -match '^export (PGHOST|PGPORT|PGUSER|PGPASSWORD|PGDATABASE)="([^"]*)"$'){$found[$Matches[1]]=$Matches[2]}}
  if($found.Count -ne 5){throw 'UNRECOGNIZED_CLI_CONNECTION_FORMAT'}
  if(!$found.PGUSER.EndsWith('.'+$target) -or $found.PGHOST -ne 'aws-0-ap-southeast-1.pooler.supabase.com'){throw 'NON_STAGING_CONNECTION_REJECTED'}
  foreach($key in $found.Keys){[Environment]::SetEnvironmentVariable($key,$found[$key],'Process')}
  & node (Join-Path $scriptDirectory 'compile-opening-balance-staging.mjs')
  if($LASTEXITCODE -ne 0){throw 'STAGING_COMPILE_FAILED'}
} finally {
  foreach($key in $previous.Keys){[Environment]::SetEnvironmentVariable($key,$previous[$key],'Process')}
}
