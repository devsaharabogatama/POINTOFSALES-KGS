# POS Session-close Stock Request Policy - Impact Map

Status: **LOCAL READY / PRODUCTION PREFLIGHT REQUIRED**

## Approved business contract

- Pengaturan per Company bernama **Permintaan stok saat tutup sesi** dan default
  `OFF`.
- `OFF` tidak menghalangi penutupan sesi. Demand procurement tetap dibekukan
  agar jejak kebutuhan dan audit tidak hilang, tetapi tidak ada Stock Request
  baru yang dibuat.
- `ON` mempertahankan flow lama: shortage reservation sesi yang ditutup
  diproyeksikan menjadi satu managed Stock Request `SUBMITTED`.
- Scheduler harian `MANUAL`, `AUTO_RO`, atau `AUTO_PO` tidak membaca switch ini
  dan tidak berubah.
- Dokumen historis tidak dibatalkan, disembunyikan, atau dibuat ulang.

## Impact map

| Area | Direct impact | Invariant |
| --- | --- | --- |
| Company setting | Boolean baru default `OFF`, setter Super Admin, optimistic version, audit before/after | Mode RO/PO, cutoff, Gudang default, dan kebijakan Stock Match tidak berubah |
| Session close | Policy disnapshot ketika Session masih `OPEN` | Cash count, close status, payment deferral, demand freeze, dan retry canonical tetap berjalan |
| Retry | Session `CLOSED` memakai snapshot awal, bukan setting terbaru | Toggle sesudah close tidak membuat request retroaktif |
| Procurement projection | Helper berhenti sebelum membuat request bila snapshot `OFF` | Existing linked request selalu dikembalikan sebagai exact retry |
| Backoffice UI | Satu switch pada Pengaturan Modul > Point of Sale | Hanya Super Admin dapat mengubah; user lain read-only |
| PWA | Pesan hasil close membaca response nested yang canonical | Tidak mengubah input atau urutan close Session |

## Downstream impact and regression risk

- Tabel yang berubah: `company_purchase_replenishment_settings` dan
  `cashier_sessions`; audit setting memakai action baru.
- RPC yang berubah: getter setting, setter policy baru, helper projection, dan
  wrapper `close_cashier_session` aktif.
- Risiko utama adalah request retroaktif saat setting berubah. Risiko ini
  ditutup oleh snapshot per Session sebelum canonical close. Existing Session
  historis mendapat default `OFF` dan tidak diproyeksikan pada retry.
- Stock, FIFO, Transfer, Receipt, Payment, Finance Event/Journal, PO, Return,
  serta scheduler harian tidak dimutasi oleh switch.
- Kondisi yang baru dapat dibuktikan setelah rollout: close authenticated pada
  Session operasional dengan shortage nyata untuk masing-masing posisi `OFF`
  dan `ON`.

## Completion evidence

Status wajib dipisahkan menjadi `LOCAL READY`, `DATABASE LIVE`,
`CLIENT DEPLOYED`, `SMOKE PASS`, dan `UAT PASS`. Lint/build atau postflight
tidak cukup untuk menyatakan fitur selesai.
