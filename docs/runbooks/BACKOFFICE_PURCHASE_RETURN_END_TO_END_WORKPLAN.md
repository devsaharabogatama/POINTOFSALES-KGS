# Backoffice Purchase Return End-to-End Workplan

**Status:** LOCAL READY  
**Tanggal:** 2026-09-19  
**Requirement:** PUR-004, PUR-003, STK-002, STK-005, FIN-001, FIN-004  
**Gate:** G5/G6 compatibility correction  
**Keputusan user:** PO/Receipt Backoffice harus dapat memulai Retur Supplier dari Backoffice tanpa Cashier Session. Jalur Retur Pembelian Retail/PWA existing tidak diubah.

## Outcome

Menyediakan flow lengkap berikut dari Backoffice:

```text
PO/Posted Goods Receipt
  -> Draft Retur Supplier
  -> Review/Approve
  -> Post Retur
  -> Stock/FIFO/AP correction
  -> Finance dependency reconciliation
  -> Cancel PO setelah net received = 0 dan dependency aman
```

Dokumen posted dan histori tidak dihapus. Koreksi wajib source-linked,
tenant-scoped, transactional, idempotent, concurrency-safe, dan audited.

## Scope yang Dikunci

### In scope

- entry point `Retur ke Supplier` dari detail PO;
- entry point `Retur Baru` dari halaman Retur Pembelian;
- pencarian sumber berdasarkan nomor PO/GR/Supplier;
- partial/full return berdasarkan exact Posted Goods Receipt;
- satu Return document per source Receipt/Warehouse agar FIFO lineage presisi;
- bulk preparation untuk PO dengan lebih dari satu Receipt tanpa mencampur
  source FIFO dalam satu Return document;
- Draft/Edit/Cancel dari Backoffice tanpa Cashier Session;
- permission Company dan capability server-side;
- review/approve/post existing yang dipertahankan;
- Stock, FIFO, Movement, AP provisional/Supplier credit boundary, Finance Event,
  audit, retry, stale version, dan reconciliation;
- PO cancellation gate setelah seluruh net received quantity nol;
- pesan blocker yang menyebut tindakan perbaikan;
- preflight, guarded migration, rollback-only behavioral test, postflight,
  authenticated smoke checklist, rollout dan forward-fix note.

### Out of scope / tidak boleh berubah

- jalur Retur Pembelian Retail/PWA dan aturan Cashier Session existing;
- Sales Return/Customer Return;
- menghapus atau mengedit dokumen Posted;
- forced Return ketika exact source FIFO sudah tidak tersedia;
- auto-cancel PO tanpa tindakan eksplisit user;
- auto-refund Supplier atau mengubah pembayaran Posted tanpa source correction.

## Impact Map

### Direct impact

- Purchase Return UI Backoffice;
- Supplier Order detail UI;
- Backoffice Purchase Return API;
- additive RPC/core untuk Draft Backoffice;
- read model sumber Return yang eligible;
- permission enforcement `purchase.purchase_returns`;
- PO cancel eligibility/read model dan pesan blocker.

### Downstream impact yang wajib dibuktikan

- `goods_receipt_documents` dan exact receipt-line condition allocation;
- `product_batches`, `product_stocks`, `stock_movements`;
- Goods Receipt AP provisional dan prior Purchase Return adjustment;
- Supplier Invoice allocation, Supplier Credit pending, dan Supplier Payment;
- Finance Event/Journal queue serta accounting period;
- Supplier Order net received/status dan daily replenishment coverage;
- audit actor/version/idempotency/tenant isolation.

### Risiko regression

- Return ganda terhadap allocation yang sama;
- Return Backoffice salah memakai Store/Cashier ownership;
- perubahan wrapper merusak PWA Retail path;
- qty Return melebihi FIFO tersisa karena transaksi konkuren;
- PO dibatalkan sementara Bill/Payment masih aktif;
- AP provisional dikurangi dua kali atau Supplier credit tidak terbentuk;
- Return multi-Receipt tercampur ke satu FIFO source;
- exact retry membuat dokumen/movement/event duplikat.

### Hasil audit call chain aktif

- Backoffice saat ini hanya dapat list/detail/review/post/cancel Draft Return;
  belum ada source picker atau RPC create/edit khusus Backoffice.
- PWA/Retail membuat Draft melalui `save_purchase_return_draft` dengan Cashier
  Session OPEN. Kontrak ini tetap dipertahankan tanpa perubahan signature.
- tabel Return mewajibkan `store_id`, `created_session_id`, dan `created_pos_id`;
  belum ada discriminator source channel.
- Post existing sudah mengunci exact source batch, mengurangi Stock/FIFO, dan
  membuat `PURCHASE_RETURN` movement secara transactional.
- Post existing baru membuat AP adjustment `AP_PROVISIONAL` atau
  `SUPPLIER_CREDIT_PENDING` serta Finance Event HOLD; Supplier Credit Note,
  settlement/refund Supplier, dan jurnal final belum tersedia.
- runtime lama sengaja memblokir Return atas Receipt yang sebagian sudah masuk
  Supplier Invoice dengan `PURCHASE_RETURN_AFTER_PARTIAL_INVOICE_REQUIRES_FINANCE_SPLIT`.
- PO cancellation sudah mensyaratkan net received nol, tetapi dependency Bill,
  Credit, dan Payment harus diperketat sebelum dipakai sebagai final gate.

### Keputusan bisnis yang dikunci

- Untuk Receipt yang baru ditagih sebagian, Return memakai
  `UNINVOICED_FIRST`: qty belum ditagih dikembalikan lebih dahulu; sisanya baru
  membentuk Supplier Credit terhadap Bill.
- Jika pembayaran sudah melampaui saldo Bill setelah Supplier Credit, selisih
  menjadi Piutang Refund Supplier. Penerimaan transfer/offset berikutnya adalah
  langkah Finance terpisah dan tidak mengubah Supplier Payment yang sudah Posted.

### Kondisi belum terbukti

- exact bentuk Supplier Bill/Payment untuk setiap PO Production;
- Finance posting runtime terbaru untuk `PURCHASE_RETURN_POSTED`;
- authenticated behavior semua preset role;
- ketersediaan exact FIFO pada saat user menekan Post.

## Checklist Implementasi

- [x] 1. Catat scope, outcome, impact map, dan boundary Retail/PWA.
- [x] 2. Audit call chain aktif UI -> API -> RPC -> table/event/test.
- [x] 3. Audit Supplier Bill/Payment/AP/Finance cancellation dependency.
- [x] 4. Finalkan contract source eligibility dan PO cancellation gate.
- [x] 5. Buat SELECT-only Production preflight.
- [x] 6. Buat guarded additive migration dan permission contract.
- [x] 7. Buat Backoffice source read model dan Draft/Edit/Cancel runtime.
- [x] 8. Integrasikan Review/Post dengan exact Stock/FIFO/AP source yang sama.
- [x] 9. Tambahkan PO detail `Retur ke Supplier` dan modal Return lengkap.
- [x] 10. Tambahkan halaman Return `Retur Baru`, filter, detail, dan blocker.
- [x] 11. Tambahkan full/multi-Receipt preparation dengan dokumen source terpisah.
- [x] 12. Tambahkan PO cancellation readiness dan dependency explanation.
- [x] 13. Buat postflight read-only.
- [x] 14. Buat rollback-only behavior/regression: partial, full, multi-Receipt
      isolation contract, prior Return, insufficient FIFO, invoice state,
      retry, stale version, cross-Company, Retail compatibility, dan cancel PO.
- [x] 15. Jalankan lint, typecheck/build, SQL structural checks, dan diff review.
- [x] 16. Perbarui source-of-truth, root README, dan active handoff.
- [x] 17. Susun urutan Production rollout dan authenticated smoke/UAT.

## PO Target Production

`PO-20260825-0000000015` diperlakukan sebagai data gate terpisah, bukan fixture
yang boleh dipaksa lolos. Evidence Production terdahulu menunjukkan:

- status `RECEIVED`;
- net received 202 base units;
- satu Posted Receipt;
- nol Supplier Bill dan nol Supplier Payment pada saat preflight tersebut;
- empat exact source GOOD FIFO allocation berjumlah 100, 20, 40, dan 42 base
  units mempunyai `qty_remaining = 0`.

Akibatnya, canonical Purchase Return harus menolak Return sampai pergerakan yang
menghabiskan FIFO tersebut ditelusuri. Implementasi ini harus menampilkan
blocker yang jelas; implementasi tidak boleh menambah stok, mengganti batch,
atau membuat forced Return hanya agar PO dapat dibatalkan.

## Status Delivery

- Local design: **COMPLETE**
- Local verification: **PASS** (lint, TypeScript/build, structural SQL, scoped diff)
- Database live: **YES** (user-confirmed migration + behavior/postflight PASS)
- Client deployed: **NO**
- Authenticated smoke: **NO**
- UAT: **NO**
