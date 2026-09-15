param([Parameter(Mandatory=$true)][string]$ProductionCatalogPath)
$ErrorActionPreference='Stop'
function ConvertTo-CanonicalJson($value) {
  if($null -eq $value) { return 'null' }
  if($value -is [System.Management.Automation.PSCustomObject]) {
    $pairs=@($value.PSObject.Properties | Sort-Object Name | ForEach-Object {
      ($_.Name | ConvertTo-Json -Compress)+':'+(ConvertTo-CanonicalJson $_.Value)
    })
    return '{'+($pairs -join ',')+'}'
  }
  if($value -is [array]) {
    $items=@($value | ForEach-Object { ConvertTo-CanonicalJson $_ })
    return '['+($items -join ',')+']'
  }
  return ($value | ConvertTo-Json -Compress)
}
$root=Split-Path -Parent $PSScriptRoot
$cloneRef='idrufihckscppsyclmsu'
$workdir=Join-Path $env:TEMP 'mads-clone-rehearsal'
if ((Get-Content -LiteralPath (Join-Path $workdir 'supabase/.temp/project-ref') -Raw).Trim() -ne $cloneRef) {
  throw 'CLONE_IDENTITY_GUARD_FAILED'
}
$productionRows=Import-Csv -LiteralPath $ProductionCatalogPath
foreach($row in $productionRows) {
  $items=ConvertFrom-Json -InputObject $row.objects
  if (@($items).Count -ne [int]$row.object_rows) { throw "INCOMPLETE_CATALOG: $($row.kind)" }
}
$previousProfile=$env:SUPABASE_PROFILE
try {
  $env:SUPABASE_PROFILE='supabase'
  # SELECT-only clone read. Never links a project or connects to Production.
  $raw=& supabase.cmd --workdir $workdir db query --linked --file `
    (Join-Path $root 'supabase/diagnostics/office_purchase_production_delta_catalog.sql') --output json
  if($LASTEXITCODE -ne 0) { throw 'CLONE_CATALOG_READ_FAILED' }
  $clone=ConvertFrom-Json -InputObject ($raw -join "`n")
} finally { $env:SUPABASE_PROFILE=$previousProfile }
$production=@{}; $rehearsal=@{}
foreach($row in $productionRows) { $production[$row.kind]=ConvertFrom-Json -InputObject $row.objects }
foreach($row in $clone.rows) {
  if (@($row.objects).Count -ne [int]$row.object_rows) { throw 'INCOMPLETE_CLONE_CATALOG' }
  $rehearsal[$row.kind]=$row.objects
}
$candidateFiles=@(Get-ChildItem -LiteralPath (Join-Path $root 'supabase/migrations') -File |
  Where-Object { ($_.Name -ge '20260908100000' -and $_.Name -lt '20260914180001') -or
    $_.Name.StartsWith('20260825131000_') -or $_.Name.StartsWith('20260915100000_') } |
  Sort-Object Name)
$installed=@{}; foreach($item in $production['application_migration']) { $installed[$item.key]=$true }
$delta=@($candidateFiles | Where-Object { -not $installed.ContainsKey($_.Name.Substring(0,14)) })
$declaredRoutines=@{}
foreach($file in $candidateFiles) {
  $sql=Get-Content -LiteralPath $file.FullName -Raw
  foreach($match in [regex]::Matches($sql,'(?i)CREATE\s+(?:OR\s+REPLACE\s+)?(?:FUNCTION|PROCEDURE)\s+([a-z_][a-z_0-9]*)\.([a-z_][a-z_0-9]*)')) {
    $declaredRoutines[($match.Groups[1].Value+'.'+$match.Groups[2].Value).ToLowerInvariant()]=$true
  }
}
$routineComparison=@(); $prodRoutines=@{}; $cloneRoutines=@{}
foreach($item in $production['routine']) { $prodRoutines[$item.key]=$item }
foreach($item in $rehearsal['routine']) { $cloneRoutines[$item.key]=$item }
foreach($key in @($prodRoutines.Keys | Sort-Object)) {
  $p=$prodRoutines[$key]; $c=$cloneRoutines[$key]
  if ($null -eq $c -or $p.details.definitionDigest -ne $c.details.definitionDigest) {
    $name=($key -split '\(')[0].ToLowerInvariant()
    $routineComparison += [pscustomobject]@{key=$key; clonePresent=($null -ne $c);
      declaredInRehearsedChain=$declaredRoutines.ContainsKey($name);
      productionDigest=$p.details.definitionDigest; cloneDigest=$c.details.definitionDigest}
  }
}
$summary=@()
foreach($kind in @('relation','constraint','trigger','index','policy','enum','extension')) {
  $p=@{}; $c=@{}
  foreach($item in $production[$kind]) { $p[$item.key]=$item }
  foreach($item in $rehearsal[$kind]) { $c[$item.key]=$item }
  $commonChanged=@($p.Keys | Where-Object { $c.ContainsKey($_) -and
    (ConvertTo-CanonicalJson $p[$_].details) -ne
    (ConvertTo-CanonicalJson $c[$_].details) } | Sort-Object)
  $summary += [pscustomobject]@{kind=$kind; productionObjects=$p.Count; cloneObjects=$c.Count;
    commonChangedCount=$commonChanged.Count; commonChangedKeys=@($commonChanged | Select-Object -First 20);
    productionOnlyKeys=@($p.Keys | Where-Object { -not $c.ContainsKey($_) } | Sort-Object)}
}
[pscustomobject]@{
  interpretation='INVENTORY ONLY: declared changes still need guard/data validation; unclassified drift is not automatically a blocker';
  cloneRef=$cloneRef; productionLedgerRows=@($production['application_migration']).Count;
  candidateAndExtraFiles=$candidateFiles.Count; missingFiles=@($delta.Name);
  productionRoutines=$prodRoutines.Count; cloneRoutines=$cloneRoutines.Count;
  changedExistingRoutines=$routineComparison;
  unchangedExistingRoutines=$prodRoutines.Count-$routineComparison.Count;
  schemaSummary=$summary
} | ConvertTo-Json -Depth 40
