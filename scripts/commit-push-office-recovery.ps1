[CmdletBinding()]
param([switch]$Execute)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root

function Invoke-RepoGit {
    param([string[]]$GitArgs)
    $result = & git.exe @GitArgs
    if ($LASTEXITCODE -ne 0) { throw "Git failed: $($GitArgs -join ' ')" }
    return $result
}

$expectedRemote = 'https://github.com/devsaharabogatama/POINTOFSALES-KGS.git'
$branch = Invoke-RepoGit -GitArgs @('branch','--show-current')
$remote = Invoke-RepoGit -GitArgs @('remote','get-url','origin')
if ($branch -ne 'main' -or $remote -ne $expectedRemote) {
    throw "STOP: expected main / $expectedRemote; actual $branch / $remote"
}
if (@(Invoke-RepoGit -GitArgs @('diff','--cached','--name-only')).Count -ne 0) {
    throw 'STOP: index already contains staged files. Review them manually; script will not unstage anything.'
}
if (@(Invoke-RepoGit -GitArgs @('ls-files','--unmerged')).Count -ne 0) {
    throw 'STOP: unresolved merge conflict.'
}

$files = @(
    'README.md'
    'backoffice/src/app/api/platform/sales-process-cutover/route.ts'
    'backoffice/src/app/page.tsx'
    'backoffice/src/components/BackofficeSalesOrderView.tsx'
    'backoffice/src/components/SalesDocumentView.tsx'
    'backoffice/src/components/SalesProcessCutoverSettings.tsx'
    'docs/ACTIVE_DEVELOPMENT_HANDOFF.md'
    'docs/README.md'
    'docs/SALES_ORDER_DUAL_INVOICE_PROCESS_NOTES.md'
    'supabase/tests/backoffice_sales_order_invoice_status_rehearsal_behavior.sql'
    'supabase/tests/sales_process_cutover_backoffice_to_retail_converter_behavior.sql'
    'docs/audits/OFFICE_SALES_RETAINED_PROCUREMENT_IMPACT_2026-09-15.md'
    'docs/runbooks/OFFICE_PROCUREMENT_RECOVERY_RELEASE_REPORT_2026-09-16.md'
    'docs/runbooks/SALES_CUTOVER_PROCUREMENT_RECOVERY.md'
    'supabase/diagnostics/cutover_recovery_runtime_audit.sql'
    'supabase/diagnostics/office_pre_dispatch_fulfillment_delta_postflight.sql'
    'supabase/diagnostics/office_pre_dispatch_fulfillment_delta_preflight.sql'
    'supabase/diagnostics/office_pre_dispatch_revision_dependencies.sql'
    'supabase/diagnostics/office_procurement_recovery_release_postflight.sql'
    'supabase/diagnostics/office_procurement_recovery_release_preflight.sql'
    'supabase/diagnostics/office_procurement_recovery_runtime_drift_diagnosis.sql'
    'supabase/diagnostics/office_sales_empty_list_cutover_diagnosis.sql'
    'supabase/diagnostics/office_sales_retained_procurement_inventory.sql'
    'supabase/diagnostics/retained_order_recovery_postflight.sql'
    'supabase/diagnostics/retained_order_recovery_preflight.sql'
    'supabase/diagnostics/retained_recovery_release_runtime_fingerprints.sql'
    'supabase/diagnostics/retained_release_fingerprint_format_audit.sql'
    'supabase/diagnostics/sales_cutover_procurement_lineage_postflight.sql'
    'supabase/diagnostics/sales_cutover_procurement_lineage_preflight.sql'
    'supabase/diagnostics/sales_cutover_procurement_retention_postflight.sql'
    'supabase/diagnostics/sales_cutover_procurement_retention_preflight.sql'
    'supabase/diagnostics/sales_cutover_procurement_runtime_definitions.sql'
    'supabase/migrations/20260915140000_sales_cutover_procurement_lineage_foundation.sql'
    'supabase/migrations/20260915141000_sales_cutover_procurement_retention_runtime.sql'
    'supabase/migrations/20260915142000_office_pre_dispatch_fulfillment_delta.sql'
    'supabase/migrations/20260916100000_cutover_absent_request_snapshot_fix.sql'
    'supabase/migrations/20260916101000_retained_order_recovery.sql'
    'supabase/migrations/20260916102000_retained_recovery_read_integration.sql'
    'supabase/releases/office_procurement_recovery_install.sql'
    'supabase/tests/office_pre_dispatch_fulfillment_delta_behavior.sql'
    'supabase/tests/office_retained_final_po_behavior.sql'
    'supabase/tests/office_retained_open_session_behavior.sql'
    'supabase/tests/office_retained_shared_request_behavior.sql'
    'supabase/tests/retained_order_recovery_behavior.sql'
    'supabase/tests/retained_recovery_concurrency_contender.sql'
    'supabase/tests/retained_recovery_concurrency_holder.sql'
    'supabase/tests/retained_release_crlf_fingerprint_behavior.sql'
    'supabase/tests/retained_release_parser_behavior.sql'
    'supabase/tests/retained_release_portable_guard_behavior.sql'
    'supabase/tests/sales_cutover_procurement_lineage_behavior.sql'
    'supabase/tests/sales_cutover_procurement_retention_behavior.sql'
    'scripts/commit-push-office-recovery.ps1'
)
foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $file) -PathType Leaf)) {
        throw "STOP: package file missing: $file"
    }
}
Write-Output "BRANCH=$branch"
Write-Output "REMOTE=$remote"
Write-Output 'Git commit identity (not necessarily the GitHub authentication account):'
Invoke-RepoGit -GitArgs @('var','GIT_AUTHOR_IDENT')
if (Get-Command gh -ErrorAction SilentlyContinue) {
    & gh auth status --hostname github.com
    if ($LASTEXITCODE -ne 0) { throw 'STOP: gh account check failed; inspect GitHub login before Execute.' }
} else {
    Write-Output 'gh CLI unavailable. Git authentication is checked by fetch/push; commit identity does not prove GitHub account.'
}
Write-Output 'PACKAGE_ALLOWLIST:'
$files
Invoke-RepoGit -GitArgs @('diff','--check')
if (-not $Execute) {
    Write-Output 'PREVIEW ONLY: no staging, commit, fetch or push. Rerun with -Execute to commit/push this package.'
    return
}

# Fetch does not merge/change the worktree. No automatic pull or force push.
Invoke-RepoGit -GitArgs @('fetch','origin','main')
$head = Invoke-RepoGit -GitArgs @('rev-parse','HEAD')
$remoteHead = Invoke-RepoGit -GitArgs @('rev-parse','refs/remotes/origin/main')
if ($head -ne $remoteHead) {
    throw 'STOP: HEAD differs from origin/main. Review local/remote commits manually; script will not push unrelated commits or auto-merge.'
}
Invoke-RepoGit -GitArgs (@('add','--') + $files)
$staged = @(Invoke-RepoGit -GitArgs @('diff','--cached','--name-only'))
$unexpected = @($staged | Where-Object { $_ -notin $files })
if ($unexpected.Count -gt 0) { throw 'STOP: unexpected staged paths; index preserved for manual review.' }
if ($staged.Count -eq 0) { throw 'STOP: no package changes to commit.' }
Invoke-RepoGit -GitArgs @('diff','--cached','--check')
Invoke-RepoGit -GitArgs @('diff','--cached','--stat')
Invoke-RepoGit -GitArgs @('commit','-m','fix: preserve procurement during Office order recovery')
Invoke-RepoGit -GitArgs @('push','origin','HEAD:main')
Write-Output 'COMMIT_AND_PUSH=PASS'
Write-Output 'If Vercel follows main, wait for deployment, then smoke-test one KMS recovery before continuing.'
