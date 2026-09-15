# Resume saved Receipt lines — client-only fix

Production evidence: KMS GR-20260914-0000000034 / PO-20260910-0000000058
has12 saved Draft lines with positive remaining qty and null legacy PO line
destinations. The former UI discarded all12 before reading saved values.

Fix: single and bulk Receive share the corrected builder. Existing saved lines
are restored by Receipt/source-line IDs regardless of null/changed PO destination
or current remaining qty. Unsaved lines still require exact Warehouse match and
positive remaining. Saved qty/UOM/disposition/client keys/SJ/notes remain intact.
Empty forms show a warning; individual Save/Post is disabled for empty lines,
and payload generation rejects empty positive quantities before a request.

No Supabase migration, backfill, data reset, link/env change, stock/FIFO/AP/Finance
writer change or permission/owner/version/idempotency bypass. Existing
STORE/DAILY_WAREHOUSE Save/Post APIs are unchanged. Other Company/POS data untouched.

Local evidence: representative12-line fixture PASS, saved values/metadata and
source unchanged; single/bulk/other Draft/other PO/Warehouse isolation, saved
zero-remaining, unsaved qty/UOM autofill/edit tests PASS. Scoped ESLint and tsc
exit0; final Next build85 pages exit0 using compile-only non-access keys, no env
file changes. Authenticated Production Save/Post and visual smoke remain user gates;
no claim that unit tests have posted the actual Production Receipt.

After client deployment: refresh Penerimaan Barang, open the same GR; all12
products and saved qty/conditions/SJ/notes must appear. Check before Save/Post.
Use existing server workflow; do not create another PO/GR. For bulk, each
Receipt has independent details and existing success/failure handling.
Rollback: revert this scoped client patch; no database rollback required.

From repository root, review staged files before committing; do not use git add .:

```powershell
git add -- backoffice/src/components/GoodsReceiptView.tsx backoffice/src/lib/goods-receipt-form.ts backoffice/scripts/test-goods-receipt-form.mjs README.md docs/README.md docs/ACTIVE_DEVELOPMENT_HANDOFF.md docs/PURCHASE_DAILY_REPLENISHMENT_SPEC.md docs/audits/PURCHASE_RECEIPT_SAVED_LINES_IMPACT_2026-09-16.md docs/runbooks/PURCHASE_RECEIPT_SAVED_LINES_FIX_2026-09-16.md supabase/diagnostics/purchase_receipt_empty_lines_diagnosis.sql
git diff --cached --name-only
git commit -m "fix: restore saved Purchase receipt lines in single and bulk Receive"
if ($LASTEXITCODE -eq 0) { git push origin main }
```
