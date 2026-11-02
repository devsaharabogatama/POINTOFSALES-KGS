# POS Direct Sales Return and Refund Finalization Impact Audit

## Classification and expected outcome

- Task classification: `PRODUCT_BEHAVIOR_CHANGE` with a likely
  `SCHEMA_OR_MIGRATION_CHANGE` because the approved optional-approval policy is
  not implemented by the active runtime.
- Requested outcome: after the Cashier confirms a valid POS Sales Return and
  refund, it becomes final without a second Backoffice approval action.
- This audit does not authorize a production mutation or deployment.

## Source of truth

- `docs/POS_DEVELOPMENT_NOTES.md` section 4.4 and
  `docs/PRODUCT_STOCK_MASTERDATA_SPEC.md` section 8.1.5 define:
  - `REQUIRED`: Cashier creates Draft; Store Manager/Admin posts;
  - `OPTIONAL`: Cashier may post directly and the result remains audited and
    visible to Store Manager.
- The requested behavior therefore has an approved business meaning, but must
  be implemented as server authority rather than a client-only bypass.

## Active execution path and identifier sources

1. `pwa/src/App.tsx` opens `pwa/src/SalesReturnModal.tsx` only for an open
   Cashier Session and the `SALES_RETURN` terminal feature.
2. `pwa/src/SalesReturnModal.tsx::submit()` validates Return lines, physical
   condition, refund method, transfer metadata, proof URL, and damaged
   Warehouse. It calls `saveSalesReturnDraft()` and tells the operator that the
   result is waiting for Store Manager/Admin approval.
3. `pwa/src/lib/pos.ts::saveSalesReturnDraft()` calls the exact RPC
   `public.save_sales_return_draft_with_delivery_fee(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb,boolean)`.
4. Its latest public wrapper is defined by
   `supabase/migrations/20260829110000_odr_phase6d_sales_return_consumer_compatibility.sql`
   and delegates to the retained delivery-fee/canonical Draft core.
5. `supabase/migrations/20260803010000_g4_phase26_sales_return_foundation.sql`
   defines `sales_return_documents.approval_mode_snapshot` with allowed values
   `REQUIRED` and `OPTIONAL`, but Draft creation omits that column. The database
   default therefore always stores `REQUIRED`.
6. The same migration defines the canonical finalization core. It locks the
   Draft, checks optimistic version and exact retry, requires an open executing
   Session, revalidates Return quantity/Warehouse/refund method, restores the
   original FIFO allocation, changes Stock, records the refund effect on the
   Session, creates an immutable `SALES_REFUND`/`SALES_RETURN` Finance Event,
   writes audit, and makes the Return `POSTED`.
7. `supabase/migrations/20260813050000_acp_phase5h_sales_return_permission_enforcement.sql`
   wraps `public.post_sales_return(uuid,bigint,uuid)` with
   `sales.sales_returns:POST`. Its retained core also unconditionally requires
   Company Owner/Admin or Store Manager; a Cashier cannot use it even if the
   document snapshot were manually changed to `OPTIONAL`.
8. `backoffice/src/app/api/sales/returns/[id]/post/route.ts` and
   `backoffice/src/components/SalesReturnApprovalView.tsx` are the only current
   final-post consumer and UI.
9. Finance posting remains governed by the existing Company Finance posting
   policy. The Return finalization creates the canonical Event; automatic
   policy may post its Journal automatically, while controlled policy retains
   the Finance queue boundary. Removing Return approval must not silently
   replace that independent Finance policy.

## Database and migration classification

- Existing Sales Return foundation, delivery-fee compatibility, ACP wrapper,
  Finance posting runtime, and ODR compatibility are recorded as installed in
  the repository gate/handoff evidence.
- Exact current production object definitions and ledger state for a new
  forward migration are `BELUM TERBUKTI` in this turn and require a SELECT-only
  preflight before rollout.
- The existing live migration versions are immutable. Any implementation must
  use a new guarded forward migration.

## Impact map

### Direct impact

- Add real server-side resolution for `REQUIRED` versus `OPTIONAL` approval.
- Snapshot the resolved policy into each new Return document.
- Provide one atomic POS operation that saves and, only when policy is
  `OPTIONAL`, finalizes the same Return with one idempotency contract.
- Change the POS submit result and wording based on final `DRAFT` versus
  `POSTED` status.
- Keep Backoffice approval for `REQUIRED` documents and historical Drafts.

### Downstream impact

- `SALEABLE` and `DAMAGED` Return Stock movements;
- original FIFO/HPP restoration and Bundle/ODR dispatched-quantity basis;
- Cash refund expected-cash reduction for the executing open Session;
- Transfer refund immutable destination/reference/method snapshot;
- Return Finance Event, automatic/controlled Journal policy, posting queue and
  exception handling;
- printed Return note and Session Summary/reporting;
- Return audit, actor, posted timestamp, optimistic version and exact retry.

### Explicitly preserved

- cumulative refundable quantity and amount caps;
- open-session, Store, Warehouse and Company boundaries;
- Cash versus Transfer validation and optional HTTPS evidence;
- Backoffice/ODR source compatibility and historical Posted/Draft rows;
- Finance Company posting mode; direct Return finalization does not imply an
  unconditional direct Journal post;
- maker/admin approval remains available when resolved mode is `REQUIRED`.

## Regression and concurrency risks

- A client-side save-then-post sequence can leave a Draft after the first call;
  the operation must be server-atomic.
- Retrying after a lost response must return the same Return, Stock, refund,
  Event and Journal outcome without duplication.
- Two terminals returning the same Sale line must serialize against cumulative
  Return quantity and original FIFO restoration.
- A closed Session must fail before any Stock/refund effect.
- Cashier authority must be granted only through the resolved `OPTIONAL` policy,
  not by weakening the general Backoffice `POST` permission.
- Existing `REQUIRED` documents must not become cashier-postable retroactively.

## Required test matrix

| Scenario | Required result |
| --- | --- |
| OPTIONAL + Cash | One confirm creates Posted Return, refund, Stock/FIFO effect and Cash-session effect atomically. |
| OPTIONAL + Transfer | One confirm creates Posted Return with immutable transfer metadata and no drawer effect. |
| REQUIRED | POS still creates Draft; Backoffice approval remains required. |
| Closed Session | Entire operation fails with zero business effect. |
| Partial/full Return | Cumulative quantity and amount remain bounded; full Return preserves exact original rounding rules. |
| SALEABLE/DAMAGED/NO_PHYSICAL_RETURN | Destination Stock/FIFO behavior remains exact for each condition. |
| ODR/legacy Retail source | Existing source-eligibility and dispatch-quantity rules remain unchanged. |
| Same/cross Company | Same-Company scope enforced; cross-Company identifiers rejected. |
| Exact retry/changed retry | Exact retry is idempotent; changed payload or stale version is rejected. |
| Finance automatic/controlled | Existing Finance policy continues to decide immediate Journal versus queue. |
| Historical Draft/Posted | No rewrite; REQUIRED Draft remains Backoffice-owned and Posted remains immutable. |

## Approved process boundary (user decision 2026-11-02)

- Direct finalization applies only while
  `company_sales_process_settings.active_mode='RETAIL_CONFIRM_INVOICE'`.
- The source Sale must also retain immutable Retail POS identity:
  `sales_headers.sales_origin='POS'` and
  `sales_headers.sales_process_mode='RETAIL_CONFIRM_INVOICE'`.
- `BACKOFFICE_DELIVERED_QTY_INVOICE` remains on Draft -> approval -> posting.
  This includes the dedicated retained-Retail return bridge used after a
  Company cutover to Backoffice; it must not inherit the direct POS shortcut.
- The active-mode identifiers are defined by
  `20260909162000_sales_process_cutover_foundation.sql`; immutable document
  identity is defined by
  `20260908100000_backoffice_sales_process_identity_foundation.sql` and its
  later cutover compatibility migrations.
- This is process routing, not a new configurable refund-approval setting.
  The existing `approval_mode_snapshot` is resolved to `OPTIONAL` only for the
  exact direct Retail operation and remains `REQUIRED` everywhere else.

## Phase B design fixed by the audit

1. A new authenticated submit RPC receives one operation UUID and the exact
   existing Return payload. It locks the Company process-setting row and source
   Sale identity before choosing a route.
2. For direct Retail POS only, the RPC calls the canonical Draft saver, stamps
   `approval_mode_snapshot='OPTIONAL'`, then invokes the canonical Return post
   core in the same database transaction. A failure rolls back Draft, Stock,
   refund, Event, and audit together.
3. The post core's approver guard gains a narrow alternative: creator equals
   actor, approval snapshot is `OPTIONAL`, source and current Company are both
   Retail POS, and the executing Session is the actor's open Session. The
   existing Owner/Admin/Store Manager branch remains unchanged.
4. For Backoffice mode or a non-POS source, the submit RPC delegates only to
   the existing Draft saver and returns `DRAFT`; Backoffice continues to use
   `public.post_sales_return` and its `sales.sales_returns:POST` permission.
5. A stored request hash plus the existing unique posting operation key makes
   exact retries return the same Posted result and rejects changed retries.
6. Finance Event creation stays inside the canonical post core. Existing
   automatic versus controlled Finance posting policy continues to decide
   Journal versus queue; this change does not bypass that separate authority.

## Remaining proof boundary

- Current production ledger/object/config state for the new forward migration
  is `UNKNOWN`; rollout remains blocked until the SELECT-only preflight proves
  `NOT_INSTALLED` with the expected active anchors.
- No unknown remains that changes the local design. Phase B still requires the
  guarded forward migration, preflight, postflight, rollback-only behavioral
  test, PWA regression, authenticated POS smoke, handoff/README updates, and
  explicit rollout/deployment authorization.

## Phase B local evidence and status

- Added guarded forward migration
  `20261102100000_pos_retail_direct_sales_return_refund.sql` plus SELECT-only
  preflight/postflight and rollback-only authenticated behavior SQL.
- PWA now submits one stable operation UUID and refund-line UUID through
  `submit_pos_sales_return_with_delivery_fee`; its result handles both the
  direct Retail `POSTED` branch and preserved Backoffice `DRAFT` branch.
- PWA lint: PASS.
- PWA production build: PASS; existing bundle-size warning only.
- Full mocked POS browser/runtime-contract gate: `29/29 PASS`. The first run was
  `28/29` because an obsolete harness assertion required the replaced Draft RPC
  name to remain in the client. Classified `TEST_HARNESS_FIX`: the corrected
  assertion requires the new client RPC and separately proves the migration
  still delegates to the canonical Draft saver. No product assertion was
  weakened.
- SQL files passed identifier/source review, delimiter review, and
  `git diff --check`. User-provided Production evidence subsequently proved the
  `NOT_INSTALLED` preflight, successful migration ledger, runtime/process and
  historical boundaries, rollback-only behavior, and postflight contracts.

Status separation:

- `AUDIT COMPLETE`: YES.
- `LOCAL READY`: YES.
- `DATABASE LIVE`: YES; migration, behavior, and postflight PASS based on
  user-provided database output.
- `CLIENT DEPLOYED`: NO.
- `SMOKE PASS`: NO.
- `UAT PASS`: NO.

Rollback/forward-fix rule: before rollout, the transaction can roll back in
full. After a successful Production commit, migration `20261102100000` is
immutable; any defect must be corrected by a new guarded forward migration.
The existing Backoffice RPC must never be replaced or dropped as rollback.
