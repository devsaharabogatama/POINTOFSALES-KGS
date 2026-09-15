# Saved Receipt lines hidden by PO warehouse filter

Evidence supplied by user: Production KMS PO-20260910-0000000058 is CONFIRMED;
GR-20260914-0000000034 is DRAFT with12 saved lines. All12 source PO destinations
are null, remaining base quantities positive, currentUiWouldShow=false. Reader
v2 and migration20260914180000 are installed. No missing-source/zero-qty theory.

Approved scope: preserve and display existing Draft lines; no PO/Receipt rewrite,
new receipt workflow, stock/FIFO/AP/payment/Finance changes. Closing compatibility
gate, tenant/source trace and draft-resume invariants.

Direct: GoodsReceiptView buildForm used by single and bulk Receive. A saved line
belongs to its existing Receipt by document_id + supplier_order_line_id. For that
Receipt, saved lines must be included irrespective of PO destination or current
remaining qty. Unsaved lines retain exact warehouse match and positive remaining
filter; null destinations do NOT authorize adding all PO lines to all warehouses.
Extract existing form builder/types into pure helper for representative tests.
Preserve keys, UOM, qty/disposition, supplier delivery number and notes. Empty
form must display a clear warning, not a blank actionable popup.

Downstream call chain unchanged: API -> save_generated_backoffice_goods_receipt
-> STORE save_backoffice_goods_receipt or DAILY_WAREHOUSE save_purchase_daily_goods_receipt;
Post -> same canonical scope-specific runtime. STORE save validates Company,
PO line membership, active Product/UOM, owner, stale version and dispositions;
it does not require the null legacy line destination. Saved Receipt warehouse
is not replaced. Existing server role/owner/version/over-receipt guards remain.

No schema/RPC/backfill change. No production reads/writes/deploy by agent in this
fix. Retry/idempotency/cashier-session/Finance/audit invariants unchanged; only
complete restored form is submitted through existing transactional writer.
Risk: widening unsaved warehouse lines or losing saved dispositions; test both
single/bulk builder,12 null-destination saved lines, other Draft/PO exclusion,
fully received saved rows, explicit warehouse rows and UOM auto-fill precision.
Rollback: revert component/helper client patch; no DB rollback/reset needed.

Production authenticated Save/Post smoke is manual and not inferred from unit
tests or compilation. A separate owner/permission failure, if encountered, must
be audited without weakening existing server access boundaries.
