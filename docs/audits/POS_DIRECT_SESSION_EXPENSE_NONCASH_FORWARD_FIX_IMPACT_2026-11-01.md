# POS Direct Session Expense Non-cash Forward Fix Impact

## Status and classification

- Classification: `SCHEMA_OR_MIGRATION_CHANGE + PRODUCT_BEHAVIOR_CHANGE`.
- Database state: `20261101100000` is `INSTALLED_INCONSISTENT` for the direct
  POS non-cash path. The installed migration is immutable and must not be
  edited or rerun.
- Unexpected behavior evidence:
  `expense_disbursement_route_check` rejected the rollback-only Transfer row
  because both `cashier_session_id` and `pos_terminal_id` were non-null.
- Previous `LOCAL READY` claim is withdrawn until a new forward migration and
  the full behavior test pass.

## Expected business outcome

1. A Cashier-entered POS Expense is paid atomically without a second approval
   or disbursement action.
2. Cash creates one Drawer OUT for the selected open session.
3. Non-cash creates no drawer movement but remains attributable to the origin
   POS session for workspace/history and Session Summary.
4. Canonical Expense Disbursement, Finance Event/Journal, audit, settlement,
   return, and additional-funding behavior remains compatible.

## Proven active call chain and identifiers

- PWA submit: `pwa/src/ExpenseRequestModal.tsx` ->
  `pwa/src/lib/pos.ts::postPosExpense` ->
  `public.post_pos_expense(...)`.
- Installed direct non-cash core:
  `private.post_pos_noncash_expense_core(uuid,bigint,uuid,text,uuid)` from
  `20261101100000_pos_direct_session_expense.sql`.
- Defining route invariant:
  `expense_disbursement_route_check` from
  `20260803070000_g4_phase34_expense_disbursement_foundation.sql`:
  non-cash routes `DIRECT_BANK/CLEARING` require disbursement
  `cashier_session_id IS NULL` and `pos_terminal_id IS NULL`.
- Origin-session authority is already stored on
  `expense_documents.cashier_session_id` and `pos_terminal_id`, defined by
  `20260803040000_g4_phase30_expense_request_approval_foundation.sql`.
- Finance posting consumer
  `private.g6_post_remaining_operational_event_core` from
  `20260814160000_g6_phase8f_remaining_operational_posting_runtime.sql`
  requires Event `amounts.cashierSessionId` to match the disbursement snapshot.

## Root cause classification

- Classification: `PRODUCT FIX`.
- The new non-cash core copied the POS origin session into the canonical
  disbursement session/terminal fields. Those fields represent Cash Drawer
  ownership, not general POS origin, for the existing table contract.
- The earlier disposable migration/postflight only proved function shape and
  source markers. It had zero runtime rows and therefore did not prove the
  behavioral invariant. That evidence must not be used as a behavior PASS.

## Forward-fix design

- Add a new guarded forward migration; never edit or rerun `20261101100000`.
- Replace only the new POS non-cash core so it:
  - still validates and locks the selected open origin session;
  - still requires the Expense document to belong to that session;
  - writes `NULL` to disbursement `cashier_session_id` and `pos_terminal_id`;
  - writes JSON `null` for Event `amounts.cashierSessionId` so the canonical
    Finance posting consumer remains valid;
  - validates exact retry ownership through the linked Expense document's
    origin session instead of the disbursement Cash Drawer fields.
- Replace the POS Expense workspace summary so disbursements join their Expense
  document and are filtered by `document.cashier_session_id`.
- Do not modify Cash behavior, the public RPC signature, Backoffice Expense,
  generic disbursement cores, or the route constraint.

## Impact map

### Direct impact

- New POS non-cash disbursement write shape.
- New POS non-cash exact-retry ownership check.
- Per-session Expense summary query.

### Downstream impact

- Finance Event validation/posting sees canonical null non-cash session
  snapshot and unchanged account/amount ownership.
- POS workspace and Session Summary still attribute non-cash to the session via
  the immutable Expense document origin.
- Settlement, return, and additional funding continue joining by document and
  disbursement identity.

### Explicitly preserved

- Cash Drawer OUT and expected-cash calculation.
- Cash/non-cash payment mapping and Finance Event amount/account snapshots.
- Backoffice approval/disbursement flows and historical rows.
- Additional funding, settlement, returns, Sales, Stock, Reservation, FIFO,
  Tempo, Offline, other Companies, and deployed client API signature.

## Regression and behavior matrix

| Case | Required result |
| --- | --- |
| Cash direct Expense | disbursement session/terminal set; one Drawer OUT |
| Non-cash direct Expense | disbursement session/terminal null; zero Drawer movement |
| Non-cash origin trace | Expense document session equals selected session |
| Non-cash Finance Event | Event session snapshot null and controlled posting valid |
| Exact non-cash retry | same result through document-origin ownership |
| Changed retry | deterministic conflict, zero additional effects |
| Session Summary | includes Cash and non-cash through document origin join |
| Another session | excluded from workspace/history/summary |
| Finance queue/Journal | one canonical Event; no duplicate posting |
| Sales/Stock/FIFO | zero effects |

## Rollback and forward-fix rule

- The failed behavior statement rolled back its attempted rows; no test-data
  cleanup migration is authorized.
- The installed migration is immutable. Any further defect must use another
  forward migration.
- Stop on any unexpected preflight, migration, behavior, postflight, Finance
  posting, authenticated smoke, or UAT failure.

## Local forward-fix evidence

- PostgreSQL 18 disposable preflight returned dependency PASS, installation
  `NOT_INSTALLED`, exact `ROOT_CAUSE`, persisted-boundary PASS, and runtime
  boundary PASS.
- Forward migration `20261101110000` compiled and committed successfully on the
  disposable database.
- Corrected postflight returned ledger PASS, runtime contract PASS, workspace
  contract PASS, and business boundary INFO.
- The first postflight result was a `TEST_HARNESS_ONLY` false negative: its
  source matcher expected `, NULL`, while exact `pg_get_functiondef` returned
  the already-correct `'cashierSessionId',NULL`. Only whitespace matching was
  corrected; the JSON-null business assertion remains mandatory.
- Production forward migration, rollback behavior, authenticated smoke, and
  UAT remain pending and must not be inferred from disposable evidence.

## Production evidence

- User-confirmed forward postflight: migration ledger PASS, runtime contract
  PASS, workspace contract PASS, and business boundary INFO.
- Runtime evidence explicitly proves Event session null, document-origin retry,
  removal of the invalid insert shape, and document-origin Session Summary.
- User supplied the exact
  `pos_direct_session_expense_behavior,PASS,0` result. It covers installed
  forward migration, authenticated active Company/open session, Cash Drawer
  OUT, non-cash without drawer effect, canonical Event/disbursement lineage,
  approval audit, exact/changed retry, selected-session workspace and totals,
  zero Sales/Stock/FIFO effect, with all test effects rolled back.

