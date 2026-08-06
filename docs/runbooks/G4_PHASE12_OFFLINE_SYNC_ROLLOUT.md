# G4 Phase 12 — Offline Sale Sync Rollout

## Outcome

Membuka RPC server untuk menerima transaksi fisik `PENDING_SYNC`, memvalidasi
payload hash/version, memakai snapshot harga offline, mencatat variance terhadap
harga server terbaru, mengonsumsi Offline Stock Allowance, lalu mem-posting
melalui runtime Sale canonical yang sama.

Phase ini belum membuka queue/API/UI PWA. Entitlement
`offline_pos_enabled` wajib tetap mati selama rollout dan baru boleh diaktifkan
setelah fase integrasi PWA serta UAT jaringan putus/nyambung.

## Invariant

- Company, Store, Terminal, Gudang, Session, Cashier, dan actor berasal dari
  context server dan Session terbuka.
- `clientTransactionId`, `postingIdempotencyKey`, payload version, client hash,
  dan server hash immutable.
- Snapshot harga offline menjadi harga transaksi final; harga server terbaru
  hanya menjadi `offline_price_variance` tanpa accounting impact.
- Allowance dikonsumsi dalam transaksi yang sama dengan Sale, Payment, FIFO,
  Movement, dan acknowledgement.
- Kegagalan posting me-rollback seluruh final effect dan meninggalkan submission
  `FAILED` yang dapat di-retry dengan identity/hash yang sama.
- Cash langsung `VERIFIED`; pembayaran elektronik menjadi
  `PENDING_VERIFICATION` dan masuk exception ledger.
- Browser tidak mendapat direct write ke Sale, Stock, allowance consumption,
  atau exception table.

## Payload minimum

`submit_pos_offline_sale(jsonb)` menerima envelope:

```json
{
  "clientTransactionId": "uuid",
  "postingIdempotencyKey": "uuid",
  "cashierSessionId": "uuid",
  "localMasterVersion": 1,
  "payloadVersion": 1,
  "localTransactionAt": "timestamptz",
  "payloadHash": "sha256-hex",
  "salePayload": {
    "clientTransactionId": "uuid yang sama",
    "cashierSessionId": "uuid yang sama",
    "customerId": "uuid",
    "isTempo": false,
    "lines": [
      {
        "lineKey": "stable-local-line-key",
        "productUomId": "uuid",
        "quantity": 1,
        "snapshotUnitPrice": 10000
      }
    ],
    "payments": [
      {
        "clientPaymentKey": "uuid",
        "paymentMethodId": "uuid",
        "amount": 10000,
        "tenderedAmount": 10000
      }
    ]
  }
}
```

`payloadHash` adalah SHA-256 lowercase dari UTF-8 canonical
`salePayload::jsonb::text`. Implementasi canonical serializer yang identik
menjadi pekerjaan fase PWA; jangan mengaktifkan offline dengan `JSON.stringify`
mentah sebelum hash cross-runtime lulus.

TEMPO offline tetap ditolak pada fase ini karena requirement menyatakan TEMPO
offline hanya Draft/Pending tanpa penyerahan barang.

## Urutan Manual

Jalankan setiap file penuh dan berhenti pada error pertama.

1. Pastikan output preflight Phase 12 tidak memiliki `BLOCKER`.
2. Jalankan
   `supabase/migrations/20260729210000_g4_phase12_offline_sale_sync.sql`.
3. Jalankan
   `supabase/diagnostics/g4_phase12_offline_sync_postflight.sql`.
   Seluruh check selain inventory `INFO` harus `PASS`.
4. Jalankan
   `supabase/tests/g4_phase12_offline_sync_tests.sql`.
   Harus menghasilkan notice `TEST PASSED` lalu `ROLLBACK`.
5. Jalankan regression:

   - `supabase/tests/g4_phase11_offline_stock_allowance_tests.sql`;
   - `supabase/tests/g4_phase8_payment_leg_identity_tests.sql`;
   - `supabase/tests/g4_phase4_atomic_sale_runtime_tests.sql`;
   - `supabase/tests/g3_phase15_inventory_core_stress_tests.sql`;
   - `supabase/tests/g1_security_closure_tests.sql`.

6. Rerun postflight Phase 12. Tidak boleh ada mismatch Stock–Movement–FIFO,
   consumption, snapshot, atau submission coverage.

## Expected Behavior Test

- satu Offline Sale memakai harga snapshot 90 saat harga server 100;
- variance `-10` tercatat tanpa mengubah harga final;
- retry submit dan retry process mengarah ke satu Sale;
- stock, FIFO, Movement, Payment, Financial Event, dan consumption masing-masing
  hanya memiliki satu final effect;
- allowance tersisa satu lalu submission quantity dua menjadi `FAILED`;
- failure tersebut tidak menyisakan Draft, consumption, atau perubahan stock;
- hash/idempotency conflict ditolak.

## Forward Fix dan Rollback

Migration bersifat additive, tetapi setelah ada submission/Sale offline jangan
drop tabel atau kolom dan jangan menghapus histori. Jika rollout migration gagal,
transaction `BEGIN/COMMIT` membatalkan seluruh perubahan.

Jika postflight/behavior gagal setelah migration applied:

1. biarkan `offline_pos_enabled` mati;
2. jangan membuka endpoint/PWA sync;
3. simpan output error dan postflight;
4. buat migration forward-fix baru;
5. jangan edit migration `20260729210000` yang sudah applied.

## Next Safe Step

Setelah migration, postflight, behavior, dan regression dinyatakan lulus:
integrasi API/PWA offline queue, retained local record, status check/retry,
acknowledgement, dan conflict UX. Aktivasi entitlement serta offline UAT tetap
menjadi gate terpisah.
