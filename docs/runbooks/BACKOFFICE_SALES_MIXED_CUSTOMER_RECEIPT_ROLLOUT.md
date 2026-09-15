# Backoffice Sales Mixed Customer Receipt — Step 4/6.3

## 2026-09-15 historical-clone rehearsal evidence

Unit 54 installed only on clone `idrufihckscppsyclmsu`: preflight eight PASS,
initial/closing postflight ten PASS, rollback-only canonical RPC behavior PASS
with 11 reported scenarios. Fixture uses Auth-backed Super Admin and guarded
Office-mode preparation, clears setup marker and asserts root-mode authority
before operational RPCs. Runtime/migration guard not bypassed or changed by fix.
Accepted 3 of shipped 4, Transit FIFO remainder 1, Invoice allocation, HOLD event,
retry and changed-payload denial executed successfully. Closing zero inventory
confirms cleanup separately. Production/client/UI smoke/UAT not executed.
Stopped before unit 55 on its missing Office-mode fixture preparation.

Status: **DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS; AUTHENTICATED UI SMOKE/UAT PENDING**
Target tunggal: Supabase Development `fkywtxucmyjvpwdiqpix`  
Production `nbxjslqojexjfogamnjt` dan staging lama `yjxpddwrjdczuqyix`: **DILARANG**

## Outcome

Runtime overload baru mencatat satu penerimaan Customer campuran secara atomik:

- accepted quantity saja dikonsumsi dari exact outbound Transit FIFO;
- accepted quantity menambah `accepted_base_qty` dan langsung membuka
  `to_invoice_base_qty`;
- quantity shortage/wrong-item tetap berada pada Transit dan Reservation;
- satu discrepancy, operation, dan audit immutable dibuat untuk DO tersebut;
- DO dan SO tetap `IN_TRANSIT` sampai resolution berikutnya;
- Regular Draft Invoice boleh mengambil accepted Qty meskipun discrepancy open;
- clean receipt tetap memakai RPC lima argumen yang sudah terbukti.

Paket ini belum menyelesaikan discrepancy, memindahkan barang kembali ke
Gudang, membuat Backorder DO/SJ, melakukan write-off lost/damaged, atau membuka
UI form disposition. Itu adalah Step 4/6.4 dan sesudahnya.

## Payload mixed receipt

RPC baru:

```text
receive_backoffice_sales_delivery(
  delivery_id, version, operation_id, accepted_date, lines, notes
)
```

Setiap DO line wajib muncul tepat sekali. Untuk quantity expected:

```text
acceptedBaseQty + SHORT/WRONG_ITEM quantityBase = shippedBaseQty
```

`OVERAGE` tidak mengurangi expected shipped quantity. Wrong Item tetap wajib
memakai actual Product/UOM/qty yang valid dan berbeda dari expected Product.
Clean receipt tanpa discrepancy sengaja ditolak oleh overload ini dan tetap
harus memakai RPC lima argumen agar idempotency payload lama tidak berubah.

## Impact map

- Direct: overload mixed receipt, receipt zero-accepted shape, accepted-only
  FIFO/Movement/COGS HOLD, discrepancy lineage, dan Regular Invoice gate.
- Downstream: Stock Transit yang belum terselesaikan tetap terkunci; resolver
  Gudang/Backorder/Finance berikutnya harus memakai discrepancy ID ini.
- Compatibility: POS Retail, clean receipt, Invoice completed-SO, Payment,
  Cashier Session, historical Stock/FIFO/Event/Journal, template Invoice/SJ,
  production, dan staging tidak diubah.
- Concurrency: row lock DO/SO/Reservation/lines/batches, operation advisory lock,
  optimistic version, exact payload retry, dan changed-payload rejection.
- Rollback: migration belum applied dapat tidak dijalankan. Setelah applied,
  gunakan forward-fix; jangan drop receipt/discrepancy history.

## Urutan manual

Jalankan utuh di SQL Editor Supabase Development:

1. `supabase/diagnostics/backoffice_sales_mixed_customer_receipt_preflight.sql`
2. `supabase/migrations/20260911166000_backoffice_sales_mixed_customer_receipt_runtime.sql`
3. `supabase/diagnostics/backoffice_sales_mixed_customer_receipt_postflight.sql`
4. `supabase/tests/backoffice_sales_mixed_customer_receipt_behavior.sql`
5. ulangi postflight nomor 3.

Stop pada SQL error, `BLOCKER`, atau `FAIL`. `INFO` bukan bukti behavioral.

## Behavioral coverage

Test rollback-only memakai call chain canonical Quotation -> Confirm SO ->
full Dispatch -> mixed receipt 3 accepted + 1 shortage. Customer aktif dipakai
bila tersedia; bila tidak, test membuat Customer lewat RPC master canonical dan
seluruh fixture tetap di-rollback:

- exact Transit FIFO berkurang hanya 3;
- sisa 1 tetap di Transit dan Reservation;
- DO/SO tetap `IN_TRANSIT`;
- Qty To Invoice menjadi 3;
- Regular Draft Invoice 3 berhasil dan memegang allocation;
- hanya satu receipt COGS Event `HOLD`, tanpa Journal sinkron;
- exact retry tidak menggandakan receipt/discrepancy/effect;
- payload retry berbeda ditolak;
- seluruh fixture di-rollback.

## Manual authenticated smoke setelah SQL PASS

Belum dijalankan melalui UI karena form disposition belum dibuka. Untuk gate
database ini, behavioral RPC adalah bukti runtime. Authenticated UI smoke wajib
dilakukan setelah Step 4/6.4 menyediakan consumer API/UI.
