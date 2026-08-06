# G4 Phase 38 — Expense Settlement Operational UI

Status: `READY FOR AUTHENTICATED ROLE SMOKE`

Phase 37 sudah dikonfirmasi user seluruhnya aman. Phase ini tidak menambah
migration: UI hanya membuka RPC settlement yang sudah guarded, tenant-scoped,
versioned, audited, dan idempotent.

## Boundary

- POS, satu menu `Expense`:
  - `Ajukan` Expense;
  - `Cairkan Tunai` Expense approved;
  - `Penyelesaian` untuk mengajukan biaya aktual, menerima pengembalian Cash,
    dan mengajukan dana tambahan.
- Backoffice `Finance > Approval Expense`:
  - review approve/reject biaya aktual;
  - menerima pengembalian non-Cash.
- Biaya aktual tidak mengubah dokumen sebelum reviewer menyetujui.
- Pengembalian Cash wajib melalui Session POS `OPEN` dan menambah expected cash.
- Pengembalian non-Cash hanya Finance/Owner/Admin dan tidak mengubah kas laci.
- Permintaan tambahan belum mencairkan dana. Eksekusinya tetap tertutup.

Offline Expense, Deposit, internal cash transfer, Customer Balance settlement,
jurnal final G6, dan Purchasing G5 tidak dibuka.

## Smoke test manual

Gunakan satu Expense yang sudah `DISBURSED` dan masih memiliki outstanding.

1. POS — buka `Expense > Penyelesaian` dan pastikan nama dokumen, kategori,
   penanggung jawab, nilai dicairkan/aktual/kembali/outstanding tampil.
2. Ajukan biaya aktual. Pastikan notifikasi menyatakan menunggu review dan nilai
   dokumen belum berubah.
3. Backoffice — buka detail Expense. Pastikan request aktual dan link bukti
   tampil; approve lalu pastikan nilai aktual naik dan outstanding turun.
4. Untuk Expense Cash, terima sisa dana dari POS. Pastikan expected cash sesi
   bertambah tepat sebesar pengembalian.
5. Untuk Expense non-Cash, terima sisa dana dari Backoffice. Pastikan tidak ada
   perubahan kas laci.
6. Ajukan dana tambahan dari POS. Pastikan hanya request yang tercatat dan tidak
   ada cash/drawer effect.
7. Ulangi aksi memakai tab lama atau versi stale; server harus menolak dengan
   `MASTER_VERSION_CONFLICT`, bukan menulis efek kedua.
8. Pastikan Escape menutup dialog yang tidak sedang menyimpan.

## Evidence lokal

- `pwa`: `npm.cmd run lint` PASS; `npm.cmd run build` PASS.
- `backoffice`: `npm.cmd run lint` PASS; `npm.cmd run build` PASS.
- Build Backoffice menemukan route review settlement dan return Expense.

## Next safe step

Setelah authenticated role/effect smoke di atas lulus, tandai Phase 38
`COMPLETE` dan lanjutkan hanya ke gate berikut dalam roadmap. Jangan membuka
eksekusi additional disbursement atau modul deferred dari UI ini.
