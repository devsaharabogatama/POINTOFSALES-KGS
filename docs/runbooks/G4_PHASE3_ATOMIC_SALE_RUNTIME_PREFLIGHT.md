# G4 Phase 3 — Atomic Sale Runtime Preflight

## Status

`COMPLETE — LIVE OUTPUT REVIEWED`

G4 Phase 2 Cashier Session telah ditutup user dengan migration, 13-check
postflight, behavioral test, dan regression seluruhnya berhasil. Phase ini
belum membuat atau mem-posting Sale. Tujuannya membekukan kondisi live sebelum
server price resolver serta atomic Sale Draft/Post dirancang.

Evidence 29 Juli 2026: user mengirim seluruh output. Semua prerequisite/data
invariant `PASS`; dua `BLOCKER` hanya checkout legacy dan empat `SETUP` tepat
pada object canonical. Hasil disetujui untuk Phase-4 database rollout.

## Scope

Jalankan:

```text
supabase/diagnostics/g4_phase3_atomic_sale_runtime_preflight.sql
```

Diagnostic SELECT-only ini mengaudit:

- dependency Pricelist, Payment Method, Tax, Bundle, dan Cashier Session;
- validitas Session `OPEN`, Store, Terminal, Cashier assignment, dan Gudang
  jual;
- exposure serta client authority checkout legacy;
- gap schema snapshot header/detail dan allocation FIFO/Bundle;
- keberadaan price resolver serta RPC Draft/Post;
- default Pricelist dan Payment Method per Store;
- Customer Pricelist, active rule, Product-UOM, Bundle, dan assigned Tax;
- rekonsiliasi Stock terhadap Movement dan FIFO;
- kesiapan Transaction Category `SALE_POSTED` dan `SALE_PAYMENT`;
- direct browser write closure serta inventory runtime.

Diagnostic tidak membuat Draft, nomor invoice, pembayaran, Movement, FIFO
allocation, Financial Event, receipt, atau offline queue.

## Expected Baseline

Baseline sebelum migration Phase 3 diperkirakan memuat:

- `BLOCKER` pada `legacy_checkout_browser_execution`;
- `BLOCKER` pada `legacy_checkout_client_authority`;
- `SETUP` pada schema header/detail/allocation dan routine canonical;
- seluruh dependency, Session, commerce master, Product, Tax assignment,
  Stock/FIFO, Finance category, history, dan direct write boundary `PASS`.

`SETUP` bukan kerusakan live. Status itu berarti object canonical memang belum
dipasang dan menjadi input migration berikutnya. Sebaliknya, `BLOCKER` data,
reference, reconciliation, atau authority selain dua legacy-checkout blocker
di atas harus direview sebelum migration ditulis.

## Cara Menjalankan

1. Buka Supabase SQL Editor.
2. Jalankan seluruh file preflight.
3. Kirim semua row `check_name,status,details`.
4. Jangan menjalankan `supabase/checkout_rpc.sql`.
5. Jangan memakai endpoint/PWA checkout legacy untuk transaksi nyata.

## Boundary Desain Berikutnya

Setelah output live disetujui:

1. buat resolver harga server dengan prioritas Customer Pricelist lalu Global
   default dan fallback Product-UOM;
2. buat Sale Draft tanpa stock, FIFO, payment, atau Finance effect;
3. buat Post Sale transactional, idempotent, version-checked, dan lock-aware;
4. hitung ulang harga, discount, Tax, rounding, payment fee, total, serta
   tender server-side;
5. konsumsi FIFO Product stock dan Bundle component secara atomic;
6. simpan semua snapshot dan buat immutable Movement serta Financial Event
   `HOLD`;
7. shortage harus mempertahankan dokumen sebagai Draft tanpa partial effect;
8. retire browser execution checkout legacy pada migration yang sama sebelum
   RPC canonical diberi `EXECUTE`.

UI/PWA dan offline queue tetap deferred sampai database behavioral,
negative-access, retry, concurrency, dan regression tests lulus.

## Rollback

Tidak ada rollback database karena preflight ini SELECT-only.
