# G4 Phase 13 — Offline PWA Queue Foundation

## Outcome

Menyiapkan penyimpanan lokal dan adapter RPC untuk Offline Sale tanpa membuka
checkout offline. Payload lokal tidak pernah dihapus setelah acknowledgement;
status, error, submission ID, dan invoice acknowledgement tetap dapat diaudit
di perangkat.

## Perubahan

- Dexie schema v3 menambah `offline_sale_queue`;
- setiap record memakai `clientTransactionId` dan
  `postingIdempotencyKey` stabil;
- payload di-hash memakai representasi yang mengikuti PostgreSQL
  `jsonb::text`; server tetap menghitung hash sendiri dan menolak mismatch;
- retry menjalankan `submit_pos_offline_sale`, lalu
  `process_pos_offline_sale_submission` dengan identity yang sama;
- status dapat direkonsiliasi melalui
  `get_pos_offline_submission_status`;
- response `POSTED` menyimpan acknowledgement lokal dan tidak menghapus
  payload.

## Boundary Aktif

- Keranjang belum dapat membuat Offline Sale;
- cache Product/harga/Tax dan konsumsi allowance lokal belum dibuka;
- endpoint legacy `/api/pos/sync` tetap menolak;
- entitlement `offline_pos_enabled` wajib tetap disabled;
- tidak ada service-role atau direct table write dari PWA.

## Verifikasi Lokal

Jalankan dari folder `pwa`:

```powershell
npm.cmd run lint
npm.cmd run build
```

Keduanya wajib PASS. Functional offline UAT belum boleh dilakukan pada phase
ini karena queue belum menjadi execution path Keranjang.

## Next Safe Step

Bangun snapshot cache Product-UOM/harga/Tax/Payment beserta allowance per
Session/Terminal. Setelah snapshot cross-runtime dan local allowance
reconciliation teruji, baru hubungkan tombol bayar offline, daftar queue,
retry/status, Slip Offline, dan conflict UX. Aktivasi entitlement serta uji
jaringan putus/nyambung tetap gate terpisah.
