# Unified Posted Backoffice Invoice Revision Rollout

## Scope and status

This package enables one Posted Regular Backoffice Invoice correction form for
KMS, LSM and SMS: billing customer selected from the Company master, Invoice
date, unit price and line discount. It preserves the original SO, DO, Invoice
header/lines, quantity, Product, UOM, Stock, reservation, FIFO and COGS.

Status on 2026-10-06:

- LOCAL READY: yes;
- STAGING DATABASE LIVE: yes, project `yjxpddwrjdczuqyixqwi` only;
- STAGING INSTALLED-RUNTIME BEHAVIOR: PASS, eight suites;
- STAGING PRODUCTION-PACKAGE REHEARSAL: PASS, nine suites / 312 tables restored;
- AUTHENTICATED STAGING HTTP SMOKE: PASS through the built Next client;
- CLIENT DEPLOYED: no;
- VISUAL BROWSER SMOKE: not run; in-app browser connector unavailable;
- UAT: pending;
- PRODUCTION PREFLIGHT: user-run PASS, 2026-10-06;
- PRODUCTION DATABASE: untouched by the agent; exact migration user-run once,
  terminal aggregate behavior PASS, and closing postflight PASS;
- PRODUCTION CLIENT DEPLOYMENT/SMOKE/UAT: pending.

This release does **not** implement a posted Receipt reversal for “payment never
occurred”, changing the date of a posted Receipt, or paying cash/bank refund from
the Invoice form. Actual refund continues through the canonical Credit Note
refund workflow. Manual due-date override and a second customer/date relocation
remain fail-closed. Do not describe those paths as completed.

## Verified artifacts

Run complete files, never selected editor fragments:

1. `supabase/diagnostics/backoffice_unified_posted_invoice_revision_preflight.sql`
   SHA256 `a72927098ce46178e5abfbf481dc752e114e1248e1850d37896eebed177b25ad`.
2. `supabase/migrations/20261006140000_backoffice_unified_posted_invoice_revision.sql`
   SHA256 `b07ad43c2dfd629d557ae07902a646838c5e5231700d52cd57372c1e1fa8ad1e`.
3. `supabase/tests/backoffice_unified_posted_invoice_revision_behavior.sql`
   SHA256 `fe4e8dbdd70781660407a793dddabac07061a5240d205e8f763e0f8a53b607a6`.
4. `supabase/diagnostics/backoffice_unified_posted_invoice_revision_postflight.sql`
   SHA256 `0375d01a6410855452401ae3b118e79c17b293079130385fac68c34834b1cb72`.

Staging installed-runtime behavior receipt:
`990f2bad3239a0ac957de6ff9f1b102672dc42def76beb8302e90ed9e4b097b3`.
The test creates representative fixtures inside a transaction and rolls all of
them back. A PASS with zero runtime inventory is not accepted as behavioral
evidence.

Authenticated staging HTTP smoke PASS at `2026-10-06T07:26:42.229Z`. It used
the staging-bound build and the real Next API routes, proving unauthenticated
denial, Company Admin Invoice read, revision POST, exact retry, effective reload,
cross-Company denial, unchanged source Invoice/lines and balanced posted revision
journals. Two earlier harness attempts completed valid revisions but stopped on
test-only output-shape assertions; no product assertion was weakened. The final
staging fixture therefore has three valid append-only revisions/journals.
All three temporary Auth actors have zero active memberships and are banned.
Closing postflight remained PASS at `2026-10-06T07:27:13.373Z` with zero active
Finance queue and zero history/schedule violations. No Production connection was
made. Visual browser interaction remains a separate manual gate because the
provided browser connector failed before opening a page.

## Production sequence — user executed only

The agent must not connect to Production, including read-only access.

### Step 1 — read-only preflight

Run the entire preflight file in the Production Supabase SQL editor and return
all result rows. Stop if any row has `BLOCKER` or `FAIL`. Do not run the migration
to work around a blocker.

Expected boundaries include: exact dependency ledger, exact active runtime
anchors, zero active Finance queue, zero nonterminal Offline submission, exact
KMS/LSM/SMS Company identity, and target-object absence.

User-returned result on 2026-10-06: all eight rows passed their required status;
`migration_ledger=0`, object collision empty, Finance/Offline queues zero,
runtime anchors and Company identity exact, and runtime inventory is three
target Companies / 226 eligible Posted Regular Invoices. Step 1 is closed.

### Step 2 — migration

Only after Step 1 is reviewed as PASS, run the entire migration file once. The
migration is transactional and guarded. Do not rerun it if its ledger row exists.

User-returned result on 2026-10-06: the exact file completed without error and
returned its expected `pg_advisory_xact_lock` result. Step 2 is closed; do not
run the migration again.

### Step 3 — rollback-only behavior

Run the complete behavior file. It must report every representative suite PASS,
including customer/date/amount revision, shared Receipt and DP attribution,
Return/Credit Note effective valuation, exact retry, immutable sources, balanced
Finance effects and transaction rollback.

This is the self-contained Production behavior package, not the internal
`backoffice_invoice_revision_writer_behavior.sql` fragment. Its exact package
was rehearsed on staging and returned nine PASS rows while restoring all 312
tracked tables. Do not run the internal fragment by itself.

The first user-run Step 3 attempt stopped at
`TEST_PRECONDITION: one-line canonical fixture required` before any business
assertion. The outer transaction rolled back. Root cause was a harness-only
assumption that every real Posted Invoice candidate had exactly one line. The
corrected package does not scan arbitrary Production Invoices for that fixture:
it records and reuses exactly two one-line Invoices created by the package
itself (one taxed correction fixture and one untaxed paid fixture). All amount,
date, customer, settlement, Finance, retry, immutability and rollback assertions
remain intact.

The next Production attempts exposed a separate harness portability defect:
first `invoice_revision_behavior_seed`, then the older
`staging_revision_invoice_fixture`, were temporary tables shared between
behavior blocks and were not present when later blocks ran through the
Production SQL Editor path. The final package removes all three temporary-table
fixtures, including authenticated/report handoff tables, and carries every
cross-block value through transaction-local PostgreSQL settings. No business
row, runtime object, or persistent helper is used for this state. A static scan
confirms zero `CREATE TEMP` and zero references to the removed tables. Fresh
staging rehearsal at `2026-10-06T08:15:00.022Z` returned nine PASS rows and
restored all 312 tracked table fingerprints.

User-returned Production result: terminal aggregate
`backoffice_unified_posted_invoice_revision_behavior PASS`, with its `tested`
array listing all nine suites through `all fixture writes rolled back`. The SQL
Editor returned only the final result set; reaching that row proves every prior
exception-guarded block completed. Step 3 is closed. Do not rerun migration or
behavior.

### Step 4 — closing postflight

Run the complete postflight file. Stop on `BLOCKER` or `FAIL`. This proves the
installed database contract only; it is not client deployment or UAT.

User-returned Production result: all contract/reconciliation rows PASS. Ledger
is exactly one; required relations/routines and public/private permissions are
exact; active Finance queue, invalid history and invalid schedules are zero.
Runtime inventory has zero real revisions/journals, which is expected before
first use and is not being used as behavioral evidence. Step 4 is closed.

### Step 5 — client deployment and authenticated smoke

Deploy the exact reviewed client commit only after Steps 1–4. Smoke with an
authorized KMS/LSM/SMS user and a disposable/approved Posted Regular Invoice:

1. open the Invoice and confirm current effective customer/date/amount;
2. open **Koreksi Invoice**;
3. verify Qty/Product/UOM are read-only;
4. change an approved field and confirm preview;
5. post once, then retry the same operation without duplicate effect;
6. reload Invoice, payment context, customer statement, export and Return path;
7. confirm SO, DO, Stock and FIFO are unchanged;
8. verify unauthorized/cross-Company access is rejected.

Do not mark `SMOKE PASS` or `UAT PASS` from SQL postflight alone.

## Compatibility and forward-fix

- Existing invoices without a unified revision read their original values.
- Existing posted price corrections remain part of effective amounts.
- Once a unified revision exists, the legacy price-only writer is blocked from
  bypassing the unified revision version.
- Posted revision history must never be deleted or rewritten. After Production
  installation, rollback is a forward-fix that can disable new entry while
  preserving readers and posted accounting lineage.
- No COA is created or remapped by this package. Missing account resolution is a
  blocker.
