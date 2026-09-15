# Production post-rollout review — release evidence, not a no-error guarantee

## Verified user-supplied evidence

- All90 installation files and final postflight: user-confirmed PASS.
- Legacy full-value reconciliation:11 tables PASS, six REVIEW; no old columns missing.
- Operational trace supplied in attachment02b33cf1: first615 chronological Movement
  candidates and first259 Event candidates match stored pre-rollout hashes exactly.
- Additional34 Movements: SALE / sales_headers / POSTED. Additional11 Events:
  sales_dispatch_financial_effects / SALE_DISPATCHED / HOLD.
- Offline inspection of the supplied trace:22 Company/Product/Warehouse groups;
  current Stock equals last additional Movement balance in every group. This is
  current ledger consistency, not exact proof of each pre-rollout Stock quantity.
- Additional Sales10/Details32, Sessions6. Older Sales/Details/Session candidate
  hashes differ. Business operations continued, as confirmed by user.

## Audited explanation to verify against actual history

Canonical Retail dispatch in20260828140000 updates old header order_runtime_status,
sj_status, reservation_version, master_version and updated_at. It also increments
old Detail fifo_cost_total/cogs_total and recomputes cogs_unit. It inserts reservation
DISPATCH_FULL/PARTIAL and document DISPATCH audits. Existing cashier Close updates
status, cash totals/variance, timestamps/version and inserts a CLOSE audit.
These are valid existing writers that can explain hashes changing; their existence
alone does not prove every observed change came from those operations.

## Impact and next evidence

New SELECT-only existing-activity audit lists recorded activity on chronological
old Sales278/Session103 candidates and their current Detail cost values. Window
starts at discovery capturedAt07:54:29Z, explicitly not atomic fingerprint time.
Baseline contains no full row values/identity manifest; no exact field-by-field
rollback reconstruction is possible from hashes alone. Unlogged changes remain
unproved and require actual before snapshot/audit, not a forced PASS or new clone
by default. Query returns INFO, not behavioral/preservation PASS.

Clone execution exit0 verifies SQL/schema; old-history window has zero candidates
on the older clone, not representative Production behavioral coverage. Production
user must run full query and retain both rows. No Production connection, mutation,
environment/link change, git commit/push, deploy, mode activation or Finance posting.

## Presentation / release boundary

### Follow-up supplied by user (attachment843739bb)

- Eleven old orders have real DISPATCH_FULL audit operations. Each current Detail
  COGS total equals its dispatch effect snapshot total; dispatch delivery ID and
  quantity agree with the audit. Current headers are DELIVERED, subsequent to the
  audited Dispatch. Delivery-completion audit was not included by this query.
- One old Session has an explicit OPEN -> CLOSED audit, matching the current
  close/status/version. This provides an operational explanation for old hashes
  changing, not an exact reconstruction of every old field from missing baseline.
- Eleven dispatch effects/events remain HOLD with null event_error. Existing
  capture_dispatch_financial_effect_core creates HOLD intentionally; controlled
  posting handles SALE_DISPATCHED. Do not force-update or auto-post for release.
- No correction justified by supplied trace alone. Proceed to client release
  preparation, not a claim of complete field-by-field preservation or UAT PASS.
- Local Vercel links resolve to pointofsales-kgs-staging (Backoffice) and
  kgs-pos-pwa-staging (POS). Names are evidence, not proof these aren't the actual
  live projects. Confirm hosting targets/branch with user before deploying; do not
  use local link blindly or relink/change Development env files.
- User subsequently reserves push/deployment to themselves. Agent performed no
  commit/push/deploy or link/env change. Fresh Backoffice lint/tsc and PWA lint/tsc
  exit0; git diff --check PASS.24 untracked source/API/lib files must not be omitted
  from release. No fresh optimized Production build/authenticated smoke claimed.

Database installation is LIVE user-confirmed. Listed clone SQL business scenarios
are verified in the historical final rehearsal report. Production client deployment,
authenticated smoke and UAT are separate and unconfirmed. Do not present all
financial events as posted: eleven additional Retail dispatch events remain HOLD;
their error/review reason is included in the follow-up query, not automatically
posted or bypassed. Release follows the existing Production client release guide
after unexplained change/operational blockers are assessed. No guarantee of zero
errors; show actual smoke evidence and retain a compatible recovery plan.
