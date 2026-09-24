# Purchase AUTO_RO Stock Match Impact — 24 September 2026

Status: `LOCAL READY`; Production belum dimigrasikan, diaktifkan, atau diuji.

## Keputusan bisnis yang dikunci

- Coverage RO hanya berasal dari batch `AUTO_RO` berstatus `DRAFT`.
- RO yang sudah menjadi PO tidak lagi dihitung sebagai RO; coverage berpindah
  ke sisa PO aktif yang belum diterima melalui lineage canonical.
- RO yang sedang dibuka tidak menghitung barisnya sendiri.
- Grain perhitungan selalu Company + Product + source Warehouse dalam base UOM.
- `Cocokkan Stok` merevisi Draft yang sama secara transactional dan audited;
  nomor RO tidak diganti.
- Stok positif hanya ditampilkan sebagai Carry Forward dan tidak dibuat menjadi
  PO. Scrap, transfer, atau stock-out tidak termasuk scope ini.
- PO tidak mengubah On Hand. Goods Receipt Posted tetap satu-satunya titik
  perubahan stok pembelian.

## Impact map

| Area | Direct impact | Downstream / boundary |
| --- | --- | --- |
| Purchase settings | Flag Company default OFF | Aktivasi pertama hanya LSM; KMS/SMS tetap lama |
| Draft AUTO_RO | Snapshot/line dapat direkonsiliasi in-place | Hanya saat belum punya PO aktif |
| PO confirmation | Wajib memakai fingerprint match terbaru saat flag ON | Qty manual berbeda memerlukan acknowledgement kedua |
| Stock/FIFO | Read-only saat preview/rematch | Tidak ada Movement, batch FIFO, Receipt, atau On Hand mutation |
| Finance/AP | Tidak berubah | Tidak ada Event, Journal, Bill, atau Payment dari rematch |
| Audit/idempotency | Operasi `RECONCILE_AUTO_RO` dan before/after snapshot | Retry exact tidak membuat revisi kedua |
| UI/API | Tab Pesanan/Stok Lebih dan tombol `Cocokkan Stok` | Client lama akan ditolak pada LSM setelah flag ON |

## Risiko regression dan guard

- Double count RO→PO dicegah dengan filter RO `DRAFT` dan remaining PO pada
  read model canonical.
- Perubahan Transfer/Return/Receipt/Adjustment/PO/RO setelah match mengubah
  fingerprint; konfirmasi fail-closed dan meminta rematch.
- Advisory lock Company, row lock batch/stock, optimistic version, idempotency
  key, dan audit snapshot melindungi concurrency/retry.
- Reconcile ditolak bila RO bukan Draft atau sudah mempunyai allocation/PO.
- Migration default OFF agar pemasangan schema tidak mengubah Company mana pun.

## Yang belum terbukti lokal

- SQL belum dijalankan terhadap Production schema.
- Authenticated browser smoke dan UAT LSM belum dilakukan.
- KMS/SMS sengaja tidak termasuk trial dan tidak boleh diaktifkan dari script LSM.

## Rollback / forward fix

- Emergency stop memakai
  `docs/runbooks/LSM_AUTO_RO_STOCK_MATCH_DEACTIVATION.sql`.
- Deactivation tidak menghapus audit atau mengubah RO/PO yang sudah terbentuk.
- Setelah migration committed, defect diperbaiki dengan migration additive baru;
  file migration live tidak diedit atau diulang.
