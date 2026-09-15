# Office / Purchase — Historical Clone Rehearsal Final Report

Date: 2026-09-15. Target: `idrufihckscppsyclmsu` only.
Production, existing staging, deployment and Company mode activation were not performed.

## Outcome and completion boundary

Database migration replay on the historical clone is complete: all **89 local
candidate versions** reconcile to its application ledger. One candidate was
already installed before rehearsal; the base delta is therefore 88, not 89.
Two additional verified dependencies/forward fixes are installed:

- `20260825131000`: missing Receipt workspace line-number projection; unchanged
  existing unapplied migration, inserted before AUTO_RO dependency checks.
- `20260915100000`: DP empty accepted-overage input compatibility fix; additive,
  applied after SO Invoice-status runtime and before Purchase continuation.

The closing reconciliation caught the omitted `20260912139000` WALK-IN payment
fix. It was audited, installed unchanged and tested through a canonical Invoice
fixture. Historical progress labels are checkpoints, not proof that a version
may be skipped. Use the actual file/ledger comparison, not timestamp-only db push.

Status: **CLONE DATABASE LIVE; SQL BEHAVIOR PASS FOR THE MATRIX BELOW**.
Authenticated browser smoke/UAT and production rollout remain separate gates.
This report does not claim every possible role/concurrency case is proved.

## Impact map and compatibility

- Direct: approved Purchase read models, daily RO/PO generation, pre-Receipt PO
  revision, generated per-Warehouse Receipt, scheduler/cancellation, Supplier
  assignment/AP bridge and the missing WALK-IN allocated-payment boundary.
- Downstream: Receipt Post creates actual Stock/FIFO/AP effects; existing Supplier
  Bill validation and Finance posting reconcile provisional/final AP; existing
  Supplier Payment settles the Invoice total, not individual products.
- Unchanged by the new fixtures: POS business flow, old transaction identities,
  existing posted Receipt/Return/Bill/Payment history, existing Company settings,
  Invoice/Bill templates and permission enforcement. No destructive reset, seed,
  down migration, commit, push or production deployment was run.
- Retry/stale protections and canonical audit/immutable history were retained.
  SQL fixtures run inside BEGIN/ROLLBACK. Sequence values may advance despite
  rollback; gaps in generated test document numbers are not persistent documents.
- Technical rollback after installed migrations means an audited additive
  forward-fix, not deleting transaction/audit rows or removing ledger versions.

## Representative behavioral evidence

| Package | Evidence / limitations |
| --- | --- |
| SO/DP/Regular Invoice + real DNI | Canonical rollback fixture: 18 scenarios PASS; actual DO Dispatch/Customer Receipt, statuses/filter/link, taxed posting, retry and strict Finance override denial. |
| WALK-IN payment + SO regression | Extended canonical fixture: 22 scenarios PASS; allocated-only payment, balanced Customer Receipt journal, unchanged Customer Balance and exact retry. |
| Accepted overage Invoice | 11 PASS; Draft edit/cancel allocation, proportional discount, partial posting/remainder, retry and over-allocation denial. Isolates approved resolved overage ledger, not physical-resolution proof. |
| Mixed physical discrepancy | 12 PASS; canonical Dispatch/receipt, approval, return/wrong-item Stock correction and linked correction DO; finalLedgerSplitVerified=true. |
| Purchase foundation / preview / AUTO_RO / AUTO_PO | Audited original rollback tests succeed; pre/postflight PASS at dependency checkpoints. Earlier warehouse-blocking intermediate policy is superseded by the final approved fixes. |
| Multiwarehouse Receipt / assignment/AP bridge | Rollback tests succeed; real Stock/FIFO, clearing/AP journals, no duplicate effect, explicit zero-cost boundary and existing Bill workspace eligibility. |
| Scheduler/cancellation | Rollback test succeeds after midnight-window fix; includes canonical Retail POS Receipt and full Purchase Return before cancel. Final scheduler postflight 11 PASS. |
| PO revision | New clone fixture: 8 PASS; canonical generator PO, Qty/price/destination, audit, retry/stale denial, filled Receipt blocks revision, zero Stock/Finance/Bill effect from revision. |
| Generated Receipt | New clone fixture: 10 PASS; empty placeholder allows PO edit, partial Post creates remaining Receipt, Bill-ready only after Posted quantity, no auto Bill. |
| Purchase through paid Supplier Bill | New canonical rollback E2E: 16 PASS; actual generated PO/Receipt, existing Bill Draft link/status, validation/posting, two payments (2 + 3 = Bill 5), balanced journals/retry, Stock-neutral Bill/Payment. |
| Receipt compatibility | Authenticated workspace reads real legacy rows; final eligibility reconciles generated active Receipt rather than all open PO. Final postflight 8 PASS including Stock/FIFO reconciliation and permissions. |

Some original tests raise on failure and only emit NOTICE on success; CLI output
then has an empty result array. Their audited assertions and successful complete
execution, not empty runtime inventory, are the behavioral evidence. Read-model
classifier tests alone are not treated as Bill/Payment end-to-end proof.

## Data preservation evidence

Sales identity/value snapshots match the user's pre-rehearsal clone output:

- Headers: 266; selected identity/value digest
  `002a8460fdc68377472594bdda9ea2bb`.
- Details: 657; quantity 55306; subtotal 1144097581; digest
  `3b140424aa36f1abd4173d8cc51d9678`.
- These projections cover document IDs/numbers, dates, status and financial
  values as defined in the retained read-only Sales snapshot query.

| Existing transactions | Before / after |
| --- | --- |
| Sales headers / details | 266 / 657, unchanged |
| Supplier orders | 56, unchanged |
| Goods Receipts | 16, unchanged |
| Purchase Returns | 0, unchanged |
| Supplier Bills / payments | 4 / 2, unchanged |
| Stock Movements / Financial Events | 585 / 245, unchanged |
| Open confirmed/partial PO | 51, digest ba3cb82575f879bc9ff7de405f20f857 unchanged |

Immediately before final Receipt migration: new eligible PO/Warehouse backfill
candidate count 0, digest d41d8cd98f00b204e9800998ecf8427e. After migration eight
existing Backoffice Receipt Drafts remain; total Receipt count stays 16. No new
final Receipt, Stock movement or financial event was created by that backfill.

Closing full-row fingerprints for 17 tables were captured before and after the
last regression group and are identical. They cover Stock/FIFO, sessions, events,
journals and Purchase/Sales documents. These are **closing-regression** exact-value
proof, not a retrospective full-row baseline for every earlier migration. Earlier
whole-chain Stock/AP preservation has count/domain reconciliation evidence; a
fresh rehearsal must capture these fingerprints before the first migration too.
The JSON evidence retains the closing values and query outputs without secrets.

Five Companies still use RETAIL_CONFIRM_INVOICE; five Purchase settings are
MANUAL. Cron is registered active at * * * * *, but no Company has automatic
Purchase enabled and scheduler runs/attempts are zero. This is not mode activation.

## New/revised files and test corrections

- Clone-specific revision and generated-Receipt preflights/tests replace old
  hardcoded Development fixture requirements with canonical rollback preparation;
  actual schema/dependency/permission/queue guards are not removed.
- Receipt workspace fixture now supports both pre-generated and final generated
  eligibility. A closing legacy assertion initially failed because it expected
  all open PO; corrected against approved final reader and retested successfully.
- Closing ledger query initially retained one `mode` reference; corrected to the
  actual `replenishment_mode` column and all four closing checks PASS.
- Local standard guarded build was denied API-key access for the separate
  Development account (403). Initial privileged-key build approach was rejected
  by safety review and was not executed. Safer compile helper uses only the clone
  public anon key, explicitly clears the server secret in the child process and
  never rewrites env files/project links or starts a server. Windows inline quoting
  was corrected by a checked-in Node helper. This is compile-only, not auth smoke.

## Local verification

- Backoffice TypeScript: PASS.
- Backoffice full lint: PASS; helper changed to ESM imports after its initial CommonJS lint rejection.
- PWA lint and TypeScript/Vite build: PASS; existing >500KB chunk warning remains.
- Backoffice optimized clone compile: PASS, 84/84 static pages; public-key-only
  compile is not runtime/authenticated smoke. Final ESM helper build also PASS
  (exit 0; TypeScript and 84/84 static pages).

## Remaining production gates — do not skip

1. Production/clone already differ: user supplied current Production 278 headers /
   693 details versus clone 266 / 657; common-266 digests also differ. This historical
   clone proves compatibility with its snapshot, not today's exact Production state.
2. User decision after this report: reuse the completed rehearsal; first inspect
   current Production read-only using the
   [delta audit package](OFFICE_PURCHASE_PRODUCTION_DELTA_READ_ONLY.md).
   Classify actual migration-input drift, not transaction count/digest differences alone.
3. Test only affected paths on the existing clone when relevant drift is found.
   A fresh clone/full replay is conditional on specific state that cannot be
   represented/proved there, not an automatic gate. Retain exact Production
   fingerprints before rollout and recapture child backfill candidates before sync.
4. Run authenticated browser Retail/Office/Purchase/Finance smoke, all intended
   custom roles and two-Company access branches, simultaneous retry/concurrency,
   open/closed sessions, pending/verified payment, partial/full dispatch and bulk
   Receipt partial-success behavior. SQL E2E is not browser/bulk UI UAT evidence.
5. Production database rollout/client deploy require explicit user authorization,
   maintenance window, fresh queue/offline checks and checkpoint postflights.
   Keep Retail and MANUAL defaults until explicit Company activation/cutover.

The local Backoffice compile artifact targets the clone URL. Do not upload that
artifact as a Production release; regenerate with the explicitly approved
Production build environment after database rollout gates. The compile helper
does not supply credentials for running authenticated server APIs.

## Evidence / manual rerun

- [Closing JSON evidence](../audits/OFFICE_PURCHASE_CLONE_REHEARSAL_CLOSING_2026-09-15.json)
- [Closing ledger reconciliation](../../supabase/diagnostics/office_purchase_clone_closing_ledger.sql)
- [Exact row fingerprints](../../supabase/diagnostics/office_purchase_clone_closing_fingerprints.sql)
- [Canonical PO through Bill/Payment rollback E2E](../../supabase/tests/purchase_bill_payment_clone_e2e_behavior.sql)
- [Canonical WALK-IN payment rollback E2E](../../supabase/tests/backoffice_sales_system_customer_payment_clone_behavior.sql)
- [Production preparation, not deployment permission](OFFICE_PURCHASE_PRODUCTION_ROLLOUT_PREPARATION.md)

Run SQL files in full, using the isolated temporary CLI workspace linked to the
authorized clone. Never run test fixtures on Production. After migration is
installed, run postflight/tests, not the migration again.
