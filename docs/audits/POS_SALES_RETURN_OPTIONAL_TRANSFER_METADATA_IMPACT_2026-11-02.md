# POS Sales Return Optional Transfer Metadata Impact Audit (2026-11-02)

## Classification and corrected outcome

- Task classification: `SCHEMA_OR_MIGRATION_CHANGE`.
- Corrected user requirement: Sales Return may use a Transfer refund without
  forcing the operator to fill a destination account. The previous audit
  incorrectly treated mandatory Transfer metadata as the requirement.
- Point 9 was not complete before this correction. Phase B is now implemented
  locally, but the corrective migration is not yet installed on the target
  database and no authenticated smoke/UAT is claimed.

## Evidence and active execution path

1. `pwa/src/SalesReturnModal.tsx` renders destination/reference only when the
   selected method type is `TRANSFER`, but both inputs have HTML `required` and
   `submit()` rejects either blank value.
2. `pwa/src/lib/pos.ts::submitSalesReturn()` already types both values as
   optional and converts empty strings to JSON `null`.
3. The client calls
   `public.submit_pos_sales_return_with_delivery_fee(...)`, installed by live
   migration `20261102100000` according to the user-provided ledger/postflight.
4. That RPC delegates to
   `public.save_sales_return_draft_with_delivery_fee(...)`, whose active wrapper
   in migration `20260829110000` delegates to
   `private.save_sales_return_draft_sld_r4(...)`, then to
   `private.save_sales_return_draft_sld_r4_core(...)`.
5. The canonical core created by migration `20260803010000` raises
   `TRANSFER_REFUND_REFERENCE_REQUIRED` when either Transfer destination or
   reference is blank.
6. The same migration defines table constraint
   `sales_return_refund_transfer_contract`, requiring both nonblank for
   Transfer and both `NULL` for non-Transfer.
7. `private.acp5h_post_sales_return_core(...)` and G6 Finance posting consume
   the persisted refund method, amount, and settlement account function.
   Destination/reference are display/audit metadata and are not inputs to
   Stock, FIFO, Cashier Session expected cash, Finance Event amount, account
   resolution, or Journal balancing.
8. Backoffice detail and print consumers already accept nullable fields. The
   print renderer currently displays `-` placeholders when Transfer metadata
   is absent and should be made explicit rather than implying recorded data.

## Identifier sources

| Identifier | Defining evidence |
| --- | --- |
| `public.sales_return_refunds.transfer_destination` | `20260803010000_g4_phase26_sales_return_foundation.sql` |
| `public.sales_return_refunds.transfer_reference` | same migration |
| `sales_return_refund_transfer_contract` | same migration, table definition |
| `TRANSFER_REFUND_REFERENCE_REQUIRED` | same migration, canonical Draft core |
| `private.save_sales_return_draft_sld_r4_core(...)` | renamed core in `20260811150000_sld_r4_explicit_delivery_fee_return.sql` |
| `private.save_sales_return_draft_sld_r4(...)` | `20260811150000_sld_r4_explicit_delivery_fee_return.sql` |
| `public.save_sales_return_draft_with_delivery_fee(...)` | latest wrapper in `20260829110000_odr_phase6d_sales_return_consumer_compatibility.sql` |
| `public.submit_pos_sales_return_with_delivery_fee(...)` | live `20261102100000_pos_retail_direct_sales_return_refund.sql` |

## Impact map

### Direct impact

- PWA: remove mandatory validation, label optional metadata truthfully, keep
  Transfer fields visible, normalize blank strings to `null`.
- Database: a new immutable forward migration must relax the existing table
  constraint and guardedly patch the active canonical Draft core. Already-live
  migrations must not be edited or rerun.
- Tests: replace the incorrect “Transfer fields required” assertion with
  Transfer-without-metadata success plus populated-metadata preservation.
- Backoffice display/print: represent absent optional metadata truthfully.

### Preserved downstream behavior

- Cash remains metadata-free; switching Transfer to Cash clears hidden state.
- Refund method eligibility, amount equality, proof HTTPS validation, Store and
  Company scope, source Sale ownership, open Cashier Session, versioning and
  exact retry remain enforced.
- Return line condition, Stock movement, FIFO restoration, HPP reversal,
  damaged-Warehouse routing, Cash expected value, Finance Event/queue/Journal,
  account mapping, audit, and historical Posted rows remain unchanged.
- POS Retail direct finalization and Backoffice Draft/approval routing remain
  separated exactly as installed by migration `20261102100000`.

### Compatibility and regression risks

- Existing rows remain valid because relaxing metadata requirements is
  backward-compatible; no backfill is required.
- Allowing empty strings instead of `NULL` would create ambiguous data. The
  canonical core must normalize blanks to `NULL`, and the new constraint must
  reject blank non-null strings.
- A UI-only patch would fail at the RPC/table layers and is invalid.
- Broadly replacing the Draft core could erase ODR compatibility patches.
  Any forward migration must anchor and preserve the active function body.

## Required regression matrix

| Scenario | Required result |
| --- | --- |
| Cash refund | No Transfer metadata persisted; existing behavior unchanged. |
| Transfer, both fields blank | Accepted only after the approved optional-metadata change. |
| Transfer, metadata populated | Exact values preserved and shown in detail/note. |
| Transfer, blank strings | Persisted as `NULL`, never empty strings. |
| Invalid proof URL | Still rejected; HTTPS proof remains optional. |
| Retail POS Return | Direct atomic finalization preserved. |
| Backoffice-mode Return | Draft/approval lifecycle preserved. |
| Existing historical Return | No rewrite/backfill. |
| Exact retry / changed retry / stale version | Existing guards preserved. |
| Stock/FIFO/Cash/Finance | Same quantities, values, events and journals. |
| Same/cross Company | Existing tenant boundary preserved. |

## Database state and preflight evidence

- `20261102100000`: `INSTALLED_CONSISTENT` from user-provided migration ledger,
  behavior PASS, and postflight PASS.
- User-provided SELECT-only preflight for this correction: all checks PASS.
  It proves the corrective state is `NOT_INSTALLED`, all four dependencies are
  installed, the active canonical core MD5 is
  `af21deff47f6947f9e5f7cfb994bb1cb`, the old mandatory constraint and
  `TRANSFER_REFUND_REFERENCE_REQUIRED` guard are still active, historical
  refund rows need no rewrite, and Finance/Offline runtime boundaries are idle.
- User decision 2026-11-02: destination, reference, and proof URL are all
  optional; blank values must normalize to `NULL`.

## Phase B implementation and verification

- Forward migration:
  `supabase/migrations/20261102110000_pos_sales_return_optional_transfer_metadata.sql`.
- Rollback-only behavior:
  `supabase/tests/pos_sales_return_optional_transfer_metadata_behavior.sql`.
- SELECT-only postflight:
  `supabase/diagnostics/pos_sales_return_optional_transfer_metadata_postflight.sql`.
- PWA removes HTML/manual mandatory validation while keeping HTTPS validation
  for a proof URL when supplied.
- Backoffice print renders only metadata actually recorded and explicitly says
  when Transfer details were not recorded.
- PWA lint: PASS.
- PWA production build: PASS; existing Vite chunk-size warning only.
- Backoffice focused lint and Return-note contract: PASS.
- Full mocked POS/runtime Playwright: `30/30 PASS`.
- First full run was `29/30`: the only failure was a static assertion that
  expected decoded SQL while the migration correctly stores an escaped
  PL/pgSQL replacement literal. This was classified `TEST_HARNESS_FIX`; the
  product invariant was retained, and the same full suite then passed 30/30.
- PostgreSQL client (`psql`) is unavailable in this environment. The database
  package was source-reviewed but has not been compiled or executed against
  the target database; local browser/contract PASS must not be treated as
  database behavior proof.

## Status and next safe step

- `AUDIT COMPLETE`: YES.
- `LOCAL READY`: YES for client code, static runtime contracts, and the guarded
  SQL package; target-database execution remains manual.
- `DATABASE LIVE`: YES for corrective migration `20261102110000`. The
  user-provided postflight passed the ledger, relaxed constraint, patched core
  (`definitionMd5=575484409620785f8fd0e114d4943f61`), blank normalization,
  zero-invalid-data, and direct-Retail/Backoffice approval boundary checks.
- `DATABASE BEHAVIOR PASS`: YES; user confirmed the installed-runtime
  rollback-only behavior completed successfully after postflight.
- `CLIENT DEPLOYED`: corrective change NO.
- `SMOKE PASS`: NO.
- `UAT PASS`: NO.

The database package is closed. Do not rerun the now immutable installed
migration. The next step is a scoped commit/push, followed by client deployment
and authenticated Return smoke; deployment, smoke, and UAT remain separate
unproven states.
