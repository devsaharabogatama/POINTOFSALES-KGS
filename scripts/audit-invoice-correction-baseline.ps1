# Read-only REST baseline; no writes to database or files. Never print credentials.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }
$values = @{}
Get-Content -LiteralPath (Join-Path $root 'backoffice/.env.local') | ForEach-Object {
  if ($_ -match '^([A-Z_]+)=(.*)$') { $values[$matches[1]] = $matches[2].Trim().Trim('"') }
}
if (-not $values['NEXT_PUBLIC_SUPABASE_URL'] -or -not $values['SUPABASE_SERVICE_ROLE_KEY']) {
  throw 'Read-only REST configuration unavailable'
}
$headers = @{ apikey = $values['SUPABASE_SERVICE_ROLE_KEY']; Authorization = ('Bearer ' + $values['SUPABASE_SERVICE_ROLE_KEY']) }
$companyFilter = 'company_id=in.(4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8,07bdffb9-8c56-444c-a49b-81ac86745674,809abdd9-d05f-4525-9726-1951a0ae1a81)'
function Get-BaselineRows([string]$Table, [string]$Columns, [string]$Filter = '') {
  $offset = 0
  do {
    $uri = $values['NEXT_PUBLIC_SUPABASE_URL'] + '/rest/v1/' + $Table + '?select=' + $Columns + '&' + $companyFilter + $Filter + '&order=id&limit=1000&offset=' + $offset
    try { $page = @(Invoke-RestMethod -Method Get -Uri $uri -Headers $headers) }
    catch { throw ('Read-only request failed for table ' + $Table + ' (' + $_.Exception.GetType().Name + ')') }
    foreach ($row in $page) { $row }
    $offset += $page.Count
  # Continue to an empty page even if the server caps pages below 1000.
  } while ($page.Count -gt 0)
}
$invoices = @(Get-BaselineRows 'backoffice_sales_invoices' 'id,company_id,invoice_no,customer_id,invoice_date,financial_event_id,grand_total' '&status=eq.POSTED&invoice_type=eq.REGULAR')
$journals = @(Get-BaselineRows 'finance_journals' 'id,company_id,financial_event_id,status,accounting_date,accounting_period_id,reversal_of_journal_id,total_debit,total_credit')
$periods = @(Get-BaselineRows 'accounting_periods' 'id,company_id,start_date,end_date,status')
$receipts = @(Get-BaselineRows 'customer_receipt_documents' 'id,company_id,customer_id,receipt_date,financial_event_id,status,total_amount,received_amount,unapplied_amount')
$allocations = @(Get-BaselineRows 'customer_receipt_backoffice_invoice_allocations' 'id,company_id,document_id,invoice_id,allocated_amount')
$dp = @(Get-BaselineRows 'backoffice_sales_down_payment_applications' 'id,company_id,regular_invoice_id,down_payment_invoice_id,applied_amount,status')
$mismatches = @()
foreach ($invoice in $invoices) {
  $sourceJournals = @($journals | Where-Object { $_.company_id -eq $invoice.company_id -and $_.financial_event_id -eq $invoice.financial_event_id -and $_.status -eq 'POSTED' -and -not $_.reversal_of_journal_id })
  if ($sourceJournals.Count -ne 1) {
    $mismatches += [pscustomobject]@{ invoiceNo = $invoice.invoice_no; companyId = $invoice.company_id; postedJournalCount = $sourceJournals.Count }
  }
}
[pscustomobject]@{
  mode = 'READ_ONLY_INVENTORY_NOT_BEHAVIORAL_PASS'
  snapshotBoundary = 'Separate REST reads, not one atomic database snapshot'
  invoiceCount = $invoices.Count
  sourceJournalMismatchCount = $mismatches.Count
  sourceJournalMismatches = $mismatches
  receiptStatuses = @($receipts | Group-Object status | Select-Object Name,Count)
  sharedBackofficeReceipts = @($allocations | Group-Object company_id,document_id | Where-Object Count -gt 1).Count
  postedDpApplications = @($dp | Where-Object status -eq 'POSTED').Count
  periodStatuses = @($periods | Group-Object status | Select-Object Name,Count)
  unbalancedPostedJournals = @($journals | Where-Object { $_.status -eq 'POSTED' -and [decimal]$_.total_debit -ne [decimal]$_.total_credit }).Count
} | ConvertTo-Json -Depth 6
