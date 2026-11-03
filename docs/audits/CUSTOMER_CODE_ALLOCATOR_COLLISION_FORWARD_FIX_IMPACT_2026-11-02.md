# Customer Code Allocator Collision Forward Fix Impact — 2026-11-02

## Classification and requested outcome

- Classification: `SCHEMA_OR_MIGRATION_CHANGE`.
- Requested outcome: Customer creation from Retail POS and Backoffice must not
  fail merely because the stored Company counter points at an existing
  `CUST-######` code. The server must allocate the next unused canonical code
  atomically while preserving per-Company uniqueness.
- Source of truth: `MST-006`, `docs/SALES_CUSTOMER_MASTERDATA_SPEC.md`, and the
  user's 2026-11-02 instruction to repair the unusable Customer create flow.

## Production evidence and current state

- The KGFF Backoffice Customer workspace was inspected read-only with
  `includeInactive=true` (the API call is proven at
  `backoffice/src/components/CustomerMasterView.tsx:65-84`). Searching
  `bahag` returned no Customer, including inactive rows.
- Searching exact code `CUST-000001` returned inactive Customer `KBU BANGKA`.
- The failed POS form used the new name `Kebab Bahagia`; therefore the observed
  collision is not the normalized-name invariant.
- The PWA maps every `DUPLICATE_CUSTOMER` to the combined name/identity message
  at `pwa/src/App.tsx:317-318`, so the user-facing error hides whether the
  violated unique key is code or name.
- The latest user-confirmed database chain includes `20261102160000`. No
  Customer allocator forward fix exists in the repository or supplied ledger
  evidence. Current Customer allocator state is classified
  `PARTIAL/INCONSISTENT`: Customer rows and unique indexes are valid, but the
  allocator can point at an occupied code after clone/import.

## Defining identifiers and active call chains

| Identifier | Defining/active source | Proven role |
| --- | --- | --- |
| `private.customer_code_sequences(company_id,next_value)` | `20260722010000_g2_phase8_customer_foundation.sql:144-148` | Legacy per-Company Customer counter. |
| `uq_customers_company_normalized_code` | same migration, Customer index section | Enforces per-Company normalized code uniqueness. Must remain. |
| `uq_customers_company_normalized_name` | same migration | Enforces approved `MST-006` name uniqueness. Must remain. |
| `public.quick_create_pos_customer(text,text,text,text,text)` | `20260730040000_g4_phase18_pos_customer_quick_create.sql` | POS create writer; allocates legacy code then inserts Customer/audit. |
| `public.save_customer(...)` | `20260722010000_g2_phase8_customer_foundation.sql` | Base Backoffice Customer create/update writer and legacy counter consumer. |
| `public.save_customer_with_parent(...)` | `20260722040000_g2_phase10_customer_grouping.sql` | Wraps `save_customer`. |
| `private.save_customer_with_pricelist(...)` | moved private by `20260812220000_acp_phase5a_customer_permission_enforcement.sql` | Adds parent/Pricelist composition. |
| `public.save_customer_with_pricelist(...)` | same ACP migration | Permission-enforced browser API writer. |
| `/api/master/customers` | `backoffice/src/app/api/master/customers/route.ts` | Calls the public ACP wrapper. |
| `quickCreatePosCustomer()` | `pwa/src/lib/pos.ts:2386-2400` | Calls POS RPC without accepting Company/code from client. |

Active paths:

1. POS `QuickCustomerModal` -> `quickCreatePosCustomer` ->
   `public.quick_create_pos_customer` -> `public.customers` +
   `customer_master_audit`.
2. Backoffice Customer form -> `/api/master/customers` ->
   public ACP wrapper -> private Pricelist wrapper -> parent wrapper ->
   `public.save_customer` -> `public.customers` + audit.

## Root cause

1. New Company provisioning initializes `customer_code_sequences.next_value`
   at `1`.
2. `20261008130000_kgff_retail_commercial_policy_clone.sql:134-160` copies KGS
   Customer codes to KGFF but does not reconcile `customer_code_sequences`.
3. Both legacy allocators increment the stored counter without checking the
   target code against `public.customers`.
4. The cloned code `CUST-000001` is already owned by inactive KGFF Customer
   `KBU BANGKA`; inactive identities correctly retain their immutable code.
5. The insert raises `unique_violation`; POS catches all such violations and
   rethrows the misleading `DUPLICATE_CUSTOMER` error. The transaction rollback
   also rolls back the counter increment, so retry repeats the same collision.

## Impact map

### Direct impact

- Introduce one private, Company-scoped Customer code allocator.
- Reconcile every Company counter forward from existing canonical
  `CUST-[0-9]+` codes without lowering any counter.
- Replace only the automatic-code branches in POS quick-create and Backoffice
  base create with the shared allocator.
- Preserve explicit Customer code on Backoffice create/update.

### Downstream impact

- Customer selector refresh and Customer audit continue unchanged.
- Parent/Pricelist wrappers receive the same result shape and signatures.
- Customer import/export retains explicit-code compatibility; an explicit code
  collision remains a real error.
- Existing inactive Customer codes remain reserved.

### Explicitly unaffected

- Sale, Return, Stock, Reservation, FIFO/HPP, Payment, Cashier Session totals,
  Customer Balance, Finance Event/queue/Journal, AR, Tempo, and audit history.
- Tenant context, open-session guard, ACP permission, Customer category,
  normalized-name uniqueness, and cross-Company isolation.
- Existing Customer IDs/codes and historical transaction snapshots.

## Concurrency, idempotency, retry, and compatibility

- Allocation must serialize per Company and must never lower/reuse a number.
- The allocator must derive a floor from both the stored counter and existing
  canonical codes, then persist the next value atomically.
- Two simultaneous POS/Backoffice creates in one Company must receive different
  codes; different Companies remain independent.
- A failed create rolls back its allocation. A normal user retry then receives
  the same still-valid code; a stale/colliding counter is advanced from live
  rows before returning a code.
- Explicit-code Backoffice behavior is preserved and continues to rely on the
  unique index.
- Applied migration versions are immutable; correction uses a new forward
  migration after `20261102160000`.

## Regression matrix

| Case | Required result |
| --- | --- |
| KGFF stale counter + occupied `CUST-000001` | next unused canonical code created; no duplicate-code failure |
| POS create with unique name | Customer/audit created in active Company and selected by UI |
| POS duplicate normalized name | rejected as `DUPLICATE_CUSTOMER_NAME`; no Customer/audit/counter effect |
| Backoffice codeless create | same shared allocator; parent/Pricelist composition preserved |
| Backoffice explicit unique code | exact explicit code preserved |
| Backoffice explicit duplicate code | rejected as code conflict |
| inactive Customer owns code | code remains reserved and allocator skips it |
| same-Company concurrent creates | distinct codes, no duplicate row |
| cross-Company creates | independent counters and no data leakage |
| unauthorized/no active Company/no OPEN POS session | existing denial unchanged |
| exact failed retry | no duplicate Customer/audit |
| existing Sales/Stock/Finance rows | zero mutation |

## Rollout and verification contract

1. SELECT-only preflight classifies ledger, active function digests, unique
   indexes, all Company counters, maximum canonical codes, and collision risk.
2. One guarded forward migration adds the allocator, reconciles counters, and
   replaces the two automatic-code consumers without changing public
   signatures.
3. SELECT-only postflight verifies ledger, function ownership/security,
   counter floors, and zero business effects.
4. Rollback-only behavior tests stale counter recovery, POS/Backoffice create,
   duplicate name, explicit code, cross-Company, authorization, and retry.
5. Authenticated smoke creates one real Customer through POS and one through
   Backoffice only after database rollout authorization.

## Unknowns and gates

- The exact current private `next_value` for KGFF is not visible in Backoffice.
  This does not change the repair design because the production UI proves an
  occupied generated code and the forward reconciliation is monotonic for all
  Companies. The preflight must still report the exact value before migration
  execution.
- No Production write or deployment is authorized by this local implementation
  task.

## Local Phase B package and evidence

- Proposed forward migration: `20261102170000`.
- Added artifacts:
  - `supabase/diagnostics/customer_code_allocator_collision_preflight.sql`;
  - `supabase/migrations/20261102170000_customer_code_allocator_collision_forward_fix.sql`;
  - `supabase/tests/customer_code_allocator_collision_behavior.sql`;
  - `supabase/diagnostics/customer_code_allocator_collision_postflight.sql`.
- Exact legacy allocator anchors were verified once in each defining writer.
- All four SQL files pass parsing through `pgsql-parser` backed by PostgreSQL
  18 `libpg_query`; dollar-quote pairs and `git diff --check` also pass.
- No database execution has occurred. `LOCAL READY` applies only to the SQL
  package; `DATABASE LIVE`, authenticated smoke, and UAT remain false.
- Rollback boundary: any failure before migration commit rolls back the whole
  transaction. Once the migration ledger is live, correction must use a new
  forward version; do not edit, delete, or rerun `20261102170000`.

## Behavioral fixture failure and re-audit

- The user ran migration `20261102170000`, then the first rollback-only
  behavior stopped while inserting two synthetic active Companies with
  `REQUIRED_ACCOUNT_MAPPING_UNRESOLVED: 1 rows`.
- Classification: `TEST HARNESS FIX`. The failure occurred before any Customer
  allocator assertion and does not prove either product success or product
  failure.
- Active failing chain is proven at
  `20260810200000_g6_phase4_atomic_single_event_posting.sql:56-197,275-294`:
  synthetic `public.companies` insert ->
  `g6_provision_posting_configuration` trigger ->
  `private.provision_g6_posting_configuration` -> required Finance mapping
  validation. The Customer test has no authority to bypass or weaken this
  Company provisioning invariant.
- Because the behavior begins with an installed-ledger assertion and reached
  the later Company insert, migration `20261102170000` is now proven ledger-live.
  Complete postflight, allocator behavior, authenticated smoke, and UAT remain
  unproven.
- Corrected fixture design must not create a Company. It will use two existing
  active Companies with active Customer categories, mutate only their private
  counters and rollback-created Customer rows inside the transaction, retain
  the same stale-counter, explicit-code, duplicate-name, Company isolation,
  POS OPEN-session, and no-session assertions, then roll everything back.
- No product function, migration, permission, Finance mapping, or assertion is
  changed by this harness correction.
- Corrected harness now selects two existing active configured Companies with
  active Customer categories and canonical Customer codes. It creates only
  rollback-scoped Customer rows, temporarily stales their private counters,
  and retains explicit-code collision, duplicate-name rollback, independent
  Company allocation, authenticated OPEN-session POS allocation, and missing
  OPEN-session denial assertions.
- PostgreSQL 18 parser validation passes for the corrected file; it contains no
  `INSERT INTO public.companies`. Database execution of the corrected behavior
  is now user-confirmed PASS.
- Proven behavioral scope: stale-counter recovery through Backoffice and POS,
  explicit-code preservation/collision denial, duplicate-name rollback,
  per-Company independence, authenticated OPEN-session POS creation, missing
  OPEN-session denial, and rollback of all test effects. Postflight,
  authenticated UI smoke, and UAT remain pending.

## Postflight harness alias failure

- The first postflight execution failed at parse/bind time with PostgreSQL
  `42P01`: the `pg_trigger` relation was aliased as `pg_trg`, while the aggregate
  still referenced `trigger.tgenabled`.
- Classification: `TEST HARNESS FIX`. No postflight assertion ran, no database
  mutation occurred, and the installed migration plus user-confirmed behavior
  result are unchanged.
- Full-file alias inventory proves one stale reference at line 32; all other
  trigger columns use `pg_trg`. The correction is restricted to that alias and
  must be re-parsed before rerun. No expected value or assertion changes.
- The alias is now corrected. PostgreSQL 18 parser, full qualified-reference
  inventory, trigger-reference inventory, and trailing-whitespace check pass.
  The user-supplied postflight rerun is now complete PASS: one ledger row,
  allocator and both automatic writers active, one enabled trigger, counter
  floors valid for all seven Companies, and private/public privilege boundaries
  intact.
- Current database evidence: migration live, corrected rollback behavior PASS,
  and postflight PASS. Authenticated POS and Backoffice smoke plus user UAT are
  still pending.
