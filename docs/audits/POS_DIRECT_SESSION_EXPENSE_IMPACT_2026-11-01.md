# POS Direct Session Expense — Impact Audit (2026-11-01)

## Classification and approved outcome

- Task classification: `SCHEMA_OR_MIGRATION_CHANGE` plus
  `PRODUCT_BEHAVIOR_CHANGE`.
- Latest user decision supersedes the previous POS Expense request/payment
  workflow only for Expense created by a Cashier from an active POS session.
- A POS Expense means the money has already left when the Cashier submits it.
  There is no separate approval, verification, or `Cairkan tunai` action.
- Cash immediately reduces the selected open Cashier Session. Non-cash does not
  change the drawer, but it is still an Expense paid from that selected POS
  session.
- Session Summary must show the total Expense paid in that session.
- POS settlement/history must show only Expense originating from the selected
  Cashier Session. Company/Backoffice history remains global within its existing
  authorization boundary.

## Source of truth and corrected Task 2 interpretation

- User decision in the active conversation on 2026-11-01 is the primary source.
- `docs/POS_EXPENSE_CASH_FLOW_SPEC.md` remains the source for tenant, payment,
  drawer, append-only settlement/return, Finance Event, audit, and correction
  invariants except where its optional approval/explicit disbursement sequence
  conflicts with the newer direct-POS decision above.
- The earlier Task 2 point 4 interpretation, "opening session cash", is revoked.
  Point 4 is total Expense paid during the selected Cashier Session plus
  session-scoped settlement/history.

## Proven active execution path before change

### PWA request path

1. `pwa/src/App.tsx` opens `ExpenseRequestModal` for an active POS session.
2. `pwa/src/ExpenseRequestModal.tsx` calls `saveExpenseDraft()` and then
   `submitExpenseRequest()`.
3. `pwa/src/lib/pos.ts` maps those calls to public RPCs
   `save_expense_draft(...)` and `submit_expense_request(uuid,bigint)`.
4. Definitions originate in migration
   `20260803040000_g4_phase30_expense_request_approval_foundation.sql`; migration
   `20260813060000_acp_phase6a_expense_permission_enforcement.sql` moves the
   implementations to `private.acp6a_*_core` and installs permission wrappers.
5. Submit currently produces `SUBMITTED` when the captured approval policy is
   enabled, or `APPROVED` when it is disabled. It never creates a disbursement.

### Existing separate payment path

1. `ExpenseRequestModal` loads `approvedCashExpenses` from
   `get_pos_expense_workspace(uuid)` and exposes `Cairkan tunai`.
2. It calls `disburse_expense(uuid,bigint,uuid,text,uuid)` through
   `disburseCashExpense()`.
3. The trusted implementation is
   `private.acp6a_disburse_expense_core`, originally defined in migration
   `20260803070000_g4_phase34_expense_disbursement_foundation.sql`.
4. It creates one immutable `expense_disbursements` row, one HOLD
   `financial_events` row, and for Cash one OUT `cash_drawer_movements` row. It
   updates the Expense document to `DISBURSED` and is idempotent by
   `(company_id,idempotency_key)`.
5. The same implementation currently rejects a POS session for non-cash and
   requires Company Owner/Admin/Finance to perform the non-cash disbursement.

### Existing settlement/history path

1. `ExpenseSettlementPanel` calls `listOutstandingExpenses()` and
   `listApprovedAdditionalCashExpenses()`.
2. Both read `get_pos_expense_workspace(uuid)`.
3. The current RPC verifies the selected open session but filters returned
   Expense rows only by `company_id + store_id`. It does not require
   `expense_documents.cashier_session_id = p_cashier_session_id`.
4. Therefore outstanding Expense from other sessions in the same Store is
   currently visible in the selected session workspace.

### Existing Session Summary path

1. `SessionSummaryModal` calls `loadCashierSessionSummary()`.
2. `pwa/src/lib/pos.ts` currently reads Sales headers/details/payments for the
   session and has no Expense total in `CashierSessionSummary`.
3. The existing `Uang awal sesi` UI is unrelated to this requirement and must
   not be presented as Task 2 point 4.

## Identifier provenance

| Identifier | Defining evidence |
| --- | --- |
| `expense_documents.cashier_session_id` | `20260803040000_g4_phase30_expense_request_approval_foundation.sql` |
| `expense_disbursements.cashier_session_id` | same migration; later operational columns added by `20260803070000...` |
| `cash_drawer_movements` | `20260803040000...` |
| `save_expense_draft`, `submit_expense_request` | `20260803040000...`, permission wrappers in `20260813060000...` |
| `private.acp6a_disburse_expense_core` | source body from `20260803070000...`, renamed by `20260813060000...` |
| `get_pos_expense_workspace` | `20260813060000_acp_phase6a_expense_permission_enforcement.sql` |
| `financial_events` type `EXPENSE_DISBURSEMENT` | consumed by the disbursement core and G6 Expense posting runtime |

No identifier in the implementation may be introduced without a defining
migration or a guarded new forward migration.

## Target call chain

1. PWA submits one direct POS Expense request with a stable client Expense ID
   and disbursement idempotency key.
2. A new public POS-only RPC validates active Company, feature, actor, Store,
   selected OPEN Cashier Session, active category/method, evidence, amount, and
   payload ownership.
3. Inside one database transaction it creates/replays the Draft snapshot,
   records direct POS approval authority for traceability, and invokes the
   existing canonical Cash core or a POS-only non-cash core that writes the
   same canonical disbursement/Event/audit shape.
4. Cash creates exactly one drawer OUT movement in the selected session.
   Non-cash creates no drawer movement but retains the selected POS session on
   the immutable disbursement and Finance Event snapshot.
5. The existing Expense Finance Event/Journal pipeline remains the only
   accounting route; no direct Journal is created by the PWA.
6. `get_pos_expense_workspace` returns only documents whose origin session is
   the selected session. The separate Backoffice reader remains Company-scoped.
7. The same workspace returns a session Expense total derived from immutable
   disbursements linked to that session. Session Summary renders that total.

## Impact map

### Direct impact

- PWA Expense submit interaction and removal of the initial `Cairkan tunai` tab.
- New guarded forward migration/RPC for atomic create-and-pay.
- A POS-only non-cash disbursement core is added; the existing generic Finance
  and Cash disbursement core remains byte-for-byte compatible.
- POS Expense workspace is narrowed from Store-wide to selected-session origin.
- Session Summary model and UI gain total Expense for the selected session.

### Downstream impact

- Cash: expected drawer cash, close-session reconciliation, drawer movement,
  audit, and Session Summary.
- Non-cash: payment account mapping, Expense disbursement Event, controlled
  Finance posting, audit, and Session Summary; no drawer effect.
- Settlement/return/additional funding remain append-only. They may operate only
  on documents visible in the selected origin session inside POS.
- Backoffice Company history, Finance review of actual settlement, Finance
  Event queue, and Journal consumers continue reading canonical tables.

### Explicitly unaffected

- Sale, Return, Stock, Reservation, FIFO/HPP, Customer Receipt, Deposit, Tempo,
  Backoffice/ODR, and other Companies.
- Existing historical Expense, disbursement, settlement, return, Event, and
  Journal rows are not rewritten or deleted.
- Additional Expense disbursement approval/payment workflow is not collapsed by
  this change; only initial Expense created directly in POS is auto-paid.

## Security, transaction, idempotency, and compatibility

- Tenant is always resolved from active Company server context; client Company
  IDs are not accepted.
- Actor must own the selected open session or have the already-approved elevated
  Store/Company authority used by POS session mutations.
- Direct create, audit transition, disbursement, drawer effect, Event, and
  document status update occur in one transaction.
- Retry uses both existing unique `client_expense_id` and immutable
  disbursement idempotency key. Same payload returns the same result; changed
  payload/key ownership fails closed.
- Stale version, closed/wrong session, cross-Company references, disabled
  feature, inactive mapping, insufficient Cash, and incompatible retry fail with
  no partial effect.
- Legacy `APPROVED` initial Expense remains payable through the retained legacy
  RPC/Backoffice compatibility path, but the PWA stops exposing the separate
  initial Cash disbursement UI for newly entered POS Expense.

## Migration/database state

- Repository defining migrations through ACP Expense enforcement are present.
- The new forward migration is `NOT_INSTALLED` because it does not exist before
  this task.
- Exact Production ledger/object state for the new forward migration is not
  needed to author local code, but remains `UNKNOWN` until a SELECT-only
  preflight is run by the user. Production execution is outside this task.
- The forward migration must guard every dependency and reject partial/drifted
  runtime state. Existing installed migrations are immutable.

## Regression matrix

| Case | Required result |
| --- | --- |
| Cash, open owned session | one DISBURSED Expense, one disbursement, one drawer OUT, one Event |
| Non-cash, open owned session | one DISBURSED Expense/disbursement/Event, zero drawer movement |
| Approval policy ON or OFF | direct POS initial Expense is paid once; policy snapshot remains auditable |
| Exact retry | same IDs/result, no duplicate document/disbursement/Event/movement |
| Changed retry payload | deterministic conflict, zero additional effect |
| Closed/wrong/cross-Company session | denied before mutation |
| Insufficient expected Cash | denied and transaction fully rolled back |
| Selected session A workspace | no documents originating from session B |
| Session Summary | total equals immutable paid Expense linked to selected session |
| Cash return in later session | receiving-session Cash In remains correct; origin workspace ownership unchanged |
| Additional disbursement | retained existing approval/disbursement behavior |
| Backoffice history and Finance queue | canonical rows remain visible/postable once only |
| Sales/Return/Stock/FIFO | zero changed effects |

## Rollback / forward-fix

- Client rollback can restore the old UI only while the new RPC remains
  additive.
- Installed migrations are never edited or removed. Any database defect uses a
  new forward migration.
- Direct POS rows already paid are immutable and must not be converted back to
  Submitted/Approved. Corrections use existing return/settlement/reversal paths.

## Phase A conclusion

- Active call chain: `PROVEN` from repository definitions above.
- Design-affecting unknown: `NONE` for local implementation.
- Production installation and authenticated smoke remain manual gates and may
  not be claimed by local tests.

## Phase B local verification evidence

- Exact forward migration `20261101100000` compiled and committed successfully
  on PostgreSQL 18 disposable after applying its defining dependency chain.
- The exact SELECT-only postflight returned four rows: migration ledger PASS,
  runtime contract PASS, workspace contract PASS, and business boundary INFO.
- PWA oxlint PASS, TypeScript/Vite production build PASS, and focused Retail
  mocked plus runtime-contract Playwright `13/13 PASS`.
- The rollback-only behavior SQL was authored but was not represented as PASS
  against the empty disposable database; it requires representative active
  Company, Store, terminal, open Cashier session, Expense category, Cash and
  non-cash method/mapping fixtures.
- Current status is strictly `LOCAL READY`. Production database, deployed
  client, authenticated smoke, and UAT remain unchanged/pending.
