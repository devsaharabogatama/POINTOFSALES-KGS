# POS Sales Return Refund Method UI Impact Audit (2026-10-31)

> **CORRECTION 2026-11-02:** audit ini salah menerjemahkan point 9 sebagai
> "Transfer wajib memiliki tujuan dan referensi". Requirement user sebenarnya
> menyatakan tujuan Transfer tidak boleh wajib. Klaim point 9 selesai dicabut.
> Audit pengganti:
> `POS_SALES_RETURN_OPTIONAL_TRANSFER_METADATA_IMPACT_2026-11-02.md`.

## Classification and requested outcome

- Task classification: `PRODUCT_BEHAVIOR_CHANGE` (presentation/operational
  workflow only; no schema or accounting mutation planned).
- Requested Task-2 items:
  - point 5: the Return flow must explain how the refund is processed and the
    final Return note must show the actual refund method;
  - point 9: Cash must not ask for a transfer destination, while Transfer must
    require destination and reference. The refund method may differ from the
    original Sale payment and remains auditable.
- Point 10 (Ketul trade-in) is explicitly out of scope for this slice.
- Production mutation/deployment: not authorized and not performed.

## Source of truth and migration state

The approved contract is in
`docs/PRODUCT_STOCK_MASTERDATA_SPEC.md` section 8.1.5: refund method is flexible
between Cash and Transfer, may differ from the original payment, and Transfer
stores destination/reference while proof is optional.

Repository handoff and gate evidence record these migrations as live and the
Sales Return foundation/PWA Draft/Backoffice approval boundaries as complete:

- `20260803010000_g4_phase26_sales_return_foundation`;
- `20260811150000_sld_r4_explicit_delivery_fee_return`;
- `20260813050000_acp_phase5h_sales_return_permission_enforcement`;
- `20260814110000_g6_phase8b_sale_return_posting_runtime`;
- `20260829110000_odr_phase6d_sales_return_consumer_compatibility`.

Database classification for the existing Return contract:
`INSTALLED_CONSISTENT` from the recorded manual rollout/behavior evidence in
`docs/ACTIVE_DEVELOPMENT_HANDOFF.md` and
`docs/POS_V1_IMPLEMENTATION_GATES.md`. This change does not edit or rerun any
of those immutable migrations.

## Active execution path and identifier evidence

### Draft creation from POS

1. `pwa/src/SalesReturnModal.tsx` loads eligible Cash/Transfer methods from the
   existing Catalog and renders `Cara refund`.
2. The same component renders `Tujuan transfer`, `Nomor referensi`, and optional
   HTTPS proof only when `selectedMethod.methodType === 'TRANSFER'`.
3. `pwa/src/lib/pos.ts::saveSalesReturnDraft()` calls the exact active RPC
   `public.save_sales_return_draft_with_delivery_fee(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb,boolean)`.
4. The latest public wrapper is defined by migration `20260829110000` and calls
   `private.save_sales_return_draft_sld_r4`, defined by migration
   `20260811150000`.
5. That private wrapper delegates to the original canonical core from migration
   `20260803010000` after delivery-fee handling.
6. The canonical core resolves an active, Store-eligible `payment_methods` row,
   permits only `CASH` or `TRANSFER`, requires destination/reference for
   Transfer, and writes an immutable method/name/type/settlement snapshot to
   `sales_return_refunds`.
7. Table constraint `sales_return_refund_transfer_contract` requires both
   fields for Transfer and requires both fields to be `NULL` for non-Transfer.

Conclusion: point 9's financial/data behavior is already implemented both
client-side and server-side. It must be retained and regression-tested, not
reimplemented with a new migration.

### Approval, posting, and final read model

1. `backoffice/src/components/SalesReturnApprovalView.tsx` loads
   `/api/sales/returns`.
2. `backoffice/src/app/api/sales/returns/route.ts` calls
   `public.get_sales_returns(text)`, defined by migration `20260813050000`.
3. The read model returns `sales_return_documents`, `sales_return_lines`, and
   `sales_return_refunds`, including method snapshot, destination, reference,
   and proof URL.
4. Approval calls `/api/sales/returns/[id]/post`, which calls the ACP-guarded
   `public.post_sales_return(uuid,bigint,uuid)` wrapper.
5. The canonical post core locks the document, enforces optimistic version,
   validates approver and open Session, revalidates the refund method, restores
   FIFO/Stock according to condition, updates Cash expected value for Cash,
   writes audit, and creates the `SALES_RETURN` Finance Event atomically.
6. G6 posting consumes the snapshotted settlement function from
   `sales_return_refunds`; no UI display change is allowed to alter that
   ownership.

The Backoffice detail already displays the refund method and conditional
Transfer metadata. The proven gap is that a final Posted Return has no printable
customer-facing Return note. Printing a Draft as if money was refunded would be
misleading, so the print action must only be available for `POSTED` documents.

## Impact map

### Direct impact

- `pwa/src/SalesReturnModal.tsx`
  - make the flexible-refund rule explicit;
  - state the Cash/Transfer consequence next to the selector;
  - clear stale Transfer-only fields when Cash is selected;
  - include the selected method in the Draft confirmation message without
    claiming the refund is final.
- `backoffice/src/components/SalesReturnApprovalView.tsx`
  - expose `Cetak Nota Return` only for Posted Return;
  - pass existing Return/customer/store/line/refund snapshots to a pure print
    renderer.
- new pure Backoffice print helper
  - escape user-controlled text;
  - show Return/invoice/customer/store/date/status, returned items, total, and
    actual refund method;
  - show destination/reference only on Transfer rows.
- tests
  - assert Cash hides/clears Transfer fields;
  - assert Transfer requires destination/reference;
  - assert the final note contains method and conditional Transfer metadata;
  - retain existing approval and Return contracts.

### Downstream consumers explicitly preserved

- source Sale and immutable original payment snapshots;
- cumulative return quantity and delivery-fee calculation;
- Store/Damaged/no-physical-return routing;
- Stock, Movement, FIFO/HPP restoration and negative-stock boundaries;
- open Cashier Session requirement and expected-cash calculation;
- Finance Event, settlement function, queue/Journal posting, and audit;
- Cash, Transfer, split Sale payment, Tempo, and Customer Balance behavior
  outside this Return boundary;
- POS versus Backoffice/ODR process separation;
- same-Company/cross-Company authorization;
- optimistic version, exact retry/idempotency, immutable Posted data, and old
  Return compatibility.

### Regression risk

- A printable Draft could be mistaken for proof of a completed refund; printing
  is therefore Posted-only.
- Unescaped customer/product/notes text could become print-window markup; all
  dynamic text must be escaped by the renderer.
- Switching Transfer to Cash can leave hidden values in React state. Although
  the server already normalizes non-Transfer values to `NULL`, the UI will also
  clear them to keep the visible payload unambiguous.
- Printing must not call a mutation or mark a document as printed because no
  canonical Return-print audit RPC exists. This slice is display-only; adding a
  print-audit event would require a separate schema audit.

## Regression matrix

| Scenario | Required result |
| --- | --- |
| Cash Draft | Transfer destination/reference/proof are hidden and omitted; server contract remains valid. |
| Transfer Draft | Destination and reference are visible and required; optional proof remains HTTPS-only. |
| Change Transfer to Cash | Transfer-only state is cleared; no hidden destination/reference is submitted. |
| Method differs from original Sale payment | Selected method snapshot remains accepted and visible in approval/note. |
| Posted Cash Return note | Shows Cash method and total; does not render transfer destination/reference. |
| Posted Transfer Return note | Shows method, destination, reference, and proof reference when present. |
| Draft/Canceled Return | No final-note print action. |
| Retry/stale version | Existing RPC behavior remains unchanged. |
| Stock/FIFO/Cash/Finance | No source changes; existing Return behavior and runtime contracts remain green. |
| Backoffice/ODR and other Companies | No execution-path change. |

## Rollback / forward-fix

No database migration, backfill, or production data change is planned.
Rollback is a source revert of the narrow PWA wording/state cleanup,
Backoffice print action/helper, and tests. Any unexpected product/runtime test
failure freezes this implementation and returns the task to read-only audit;
assertions must not be weakened to obtain PASS.

## Verification and current status

- Pure Return-note contract test: PASS. It covers Cash and Transfer output,
  conditional metadata, HTML escaping, and the Posted-only print boundary.
- PWA lint: PASS.
- PWA TypeScript/Vite production build and service-worker generation: PASS.
- Backoffice focused ESLint for the changed component/helper: PASS.
- Backoffice production build: PASS (`89` routes generated).
- Combined mocked Retail and runtime-contract Playwright: `11/11 PASS`,
  including Cash-hidden/Transfer-required fields and clearing stale values when
  the operator switches back to Cash.

Status by layer:

- `AUDIT COMPLETE`: yes.
- `LOCAL READY`: yes.
- `DATABASE LIVE`: the pre-existing canonical Return runtime is live and was
  not modified by this slice.
- `CLIENT DEPLOYED`: no.
- `AUTHENTICATED SMOKE PASS`: no; requires deployment first.
- `UAT PASS`: no.

Manual gate after an explicitly authorized deployment: create one Cash Return
Draft and one Transfer Return Draft without changing Company, post them through
the existing Backoffice approval flow, open each Posted detail, and verify the
printed note shows the actual method while Transfer metadata appears only on
the Transfer note.
