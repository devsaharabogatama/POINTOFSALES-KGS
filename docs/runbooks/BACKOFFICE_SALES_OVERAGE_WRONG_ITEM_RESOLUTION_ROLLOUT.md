# Backoffice Sales Overage/Wrong Item Resolution — Step 4/6.5C3

Status: **DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS ON ISOLATED
DEVELOPMENT; AUTHENTICATED SMOKE/UAT PENDING**.
Target hanya `fkywtxucmyjvpwdiqpix`. Production `nbxjslqojexjfogamnjt` dan
staging lama `yjxpddwrjdczuqyix` dilarang.

> Koreksi lanjutan: audit Step 5/6.3 menemukan accepted overage juga ditambahkan
> ke regular SO accepted ledger sehingga Invoice dapat membaca quantity yang sama
> dari dua source. Jangan memakai behavior C3 lama sebagai bukti terbaru sebelum
> menjalankan forward-fix dan behavioral terkoreksi pada
> [`BACKOFFICE_SALES_ACCEPTED_OVERAGE_LEDGER_SPLIT_FIX.md`](BACKOFFICE_SALES_ACCEPTED_OVERAGE_LEDGER_SPLIT_FIX.md).

## Historical clone grouped execution — 2026-09-15

- `130000`/`131000`/`132000` installed on clone only; preflight and initial/closing
  postflight all PASS. Five actual Company Finance catalogs/rules reconciled.
- Stage-aware rollback-only behavior 12 scenarios PASS after fixing CASE syntax
  error 42601. Output historical_pre_split, finalLedgerSplitVerified=false.
  Physical mixed receipt, exact FIFO returns, correction DO, version/retry proven;
  final Invoice double-count fix is NOT proven until `137000` + retest.
- Applied migrations unchanged; no Production/client deployment or persistent
  fixture Stock/payment changes. Progress now 66/88 with C4 also PASS.

## Historical clone audit boundary — 2026-09-15

- Progress remains 62/88 installed on `idrufihckscppsyclmsu`. C3 preflight nine
  PASS; base migration and C3 behavioral NOT executed this turn.
- Fixture actor/Auth and Office-mode setup corrected rollback-only, setup marker
  cleared before root-creation assertion/RPC; preparation still unexecuted.
- Stop before base mutation: base inserts forbidden CORRECTION child kind;
  existing `131000` fixes it. `132000` fixes Finance catalog/rule identity and
  final C3 behavior requires `137000` separate ledger. Standalone preflight or
  zero-row postflight cannot establish runtime compatibility.
- Next execution must explicitly gate this dependency group; do not edit applied
  migrations, weaken constraints, or remove final behavior prerequisites.
  Production/client unchanged; authenticated smoke/UAT remain pending.

## Outcome dan impact

- `ACCEPT_OVERAGE`: source→Transit direkonstruksi exact FIFO, qty dikonsumsi
  sebagai sale, accepted overage menjadi Qty To Invoice, dan COGS dicatat pada
  Financial Event HOLD terpisah dari receipt awal.
- `RETURN_OVERAGE`: source→Transit direkonstruksi lalu dikembalikan ke Gudang
  asal dengan dua Stock Transfer dan lineage terpisah.
- `REPLACE_WRONG_ITEM`: actual Product direkonstruksi dan dikembalikan, phantom
  expected Product dari Dispatch dikembalikan, lalu dibuat child DO/SJ canonical
  `BACKORDER` pada SO yang sama. Tujuan bisnisnya tetap dibedakan secara eksplisit
  oleh lineage `resolution_kind=WRONG_ITEM_CORRECTION`; tanggal default tanggal
  Company dan dapat diedit Admin.
- Mixed case harus menyelesaikan shortage terlebih dahulu. Child Shortage
  Backorder dan Wrong Item Correction dipisah agar jenis serta histori SJ jelas.

Tidak mengubah POS Retail, Invoice template/number, Payment, Cashier Session,
harga/diskon/pajak approval, atau jurnal receipt lama. Event COGS overage tetap
HOLD sampai Finance closure berikutnya; migration ini tidak mem-posting jurnal.

## Root cause forward-fix 20260912131000

Behavior pertama membuktikan resolver `130000` mencoba menyimpan
`delivery_kind=CORRECTION`. Nilai itu berasal dari foundation awal `145000`,
tetapi kontrak aktif `146000` sengaja membatasi child DO hanya `BACKORDER`.
Migration `130000` yang sudah applied tidak diubah. Forward-fix mengganti tepat
satu anchor pada private resolver; constraint global dan public RPC tetap.

## Root cause forward-fix 20260912132000

Behavior kedua melewati pembuatan child DO lalu berhenti pada FK
`financial_events.system_event_key`. C3 membuat key terpisah
`BACKOFFICE_ACCEPTED_OVERAGE_COGS`, tetapi tidak membuat master `system_events`.
Audit lanjutan juga membuktikan resolver masih menunjuk category `SALE_POSTED`
dan tidak menyimpan `transaction_rule_version`; menambah satu row event saja
akan meninggalkan mapping Finance tidak konsisten.

Forward-fix `132000` menyediakan event, category, account rule COGS/Inventory,
approved posting-rule snapshot untuk seluruh Company aktif dan Company baru,
lalu mengganti tepat empat anchor Finance pada private resolver. Event tetap
`HOLD`; posting jurnalnya tetap gate Finance berikutnya.

## Urutan manual wajib setelah error Finance tersebut

1. [`Finance-catalog preflight`](../../supabase/diagnostics/backoffice_sales_accepted_overage_finance_catalog_fix_preflight.sql)
2. [`Finance-catalog migration`](../../supabase/migrations/20260912132000_backoffice_sales_accepted_overage_finance_catalog_fix.sql)
3. [`Finance-catalog postflight`](../../supabase/diagnostics/backoffice_sales_accepted_overage_finance_catalog_fix_postflight.sql)
4. [`Delivery-kind postflight`](../../supabase/diagnostics/backoffice_sales_wrong_item_delivery_kind_fix_postflight.sql)
5. [`Behavioral rollback-only terkoreksi`](../../supabase/tests/backoffice_sales_overage_wrong_item_resolution_behavior.sql)
6. [`C3 postflight`](../../supabase/diagnostics/backoffice_sales_overage_wrong_item_resolution_postflight.sql)
7. Jalankan kedua forward-fix postflight sekali lagi setelah behavioral PASS.

Jalankan setiap file utuh. Stop pada SQL error, `BLOCKER`, atau `FAIL`.
`INFO`/zero runtime rows bukan bukti behavior. Migration applied tidak boleh
diedit; koreksi wajib forward migration.

## Rollback / forward fix

Forward rollback `131000` hanya boleh mengganti anchor private resolver kembali
jika belum ada operational resolution dan akan mengembalikan kegagalan lama;
tidak direkomendasikan. Setelah ada resolution, jangan menghapus
Stock/FIFO/Event/DO lineage; gunakan forward fix additive dan pertahankan audit
immutable.

Finance catalog `132000` mempunyai immutable master/rule audit. Setelah applied,
jangan menghapus category/rule/audit untuk rollback. Jika mapping perlu diubah,
buat versioned rule baru dan retire rule lama melalui forward-fix; event C3 yang
sudah tercipta tidak boleh di-rewrite atau dipindahkan ke category lain.

## Smoke setelah SQL PASS

Uji authenticated: accepted overage→Qty To Invoice, return overage→On Hand,
wrong item→DO/SJ correction, exact retry, stale version, permission Gudang,
Warehouse minus OFF/ON, dan Company silang. Finance harus memperlihatkan event
accepted-overage COGS HOLD, tanpa mengubah event receipt awal.
