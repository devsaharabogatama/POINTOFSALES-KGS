# ODR-1 Live Contract Audit

**Status:** PRE-FLIGHT READY — SELECT-only audit menunggu hasil Supabase live  
**Parent plan:** `docs/POS_ORDER_RESERVATION_DISPATCH_FINANCE_PLAN.md`  
**Scope:** membekukan batas cutover sebelum schema dan runtime ODR-2 dibuat.

## 1. Temuan runtime saat ini

1. `post_pos_sale` masih merupakan finalisasi Sale: jalur private-nya menulis
   Stock balance, Stock Movement, FIFO allocation, Payment snapshot, Invoice,
   Financial Event, dan efek terkait dalam satu proses.
2. perubahan status `sales_delivery_documents` saat ini hanya mengubah lifecycle
   Surat Jalan dan `sales_headers.sj_status`; Dispatch belum menjadi pemilik efek
   Stock/FIFO.
3. Invoice dan Surat Jalan saat ini dibuat dari Sale berstatus `POSTED`.
4. kebutuhan otomatis per sesi sudah ada, tetapi hanya bersumber dari
   `negative_stock_sale_allocations` ketika sesi ditutup.
5. Supplier Order hanya dapat diubah saat `DRAFT`. Setelah Confirm, perubahan
   kebutuhan tidak boleh menimpa line PO final.
6. Scheduled TEMPO yang sudah ada tetap berupa Draft tanpa final effect sampai
   Post. Data ini menjadi input compatibility untuk ODR-2, bukan dihapus.

Temuan 1–4 adalah gap arsitektur yang memang direncanakan. Hasil tersebut harus
berstatus `REVIEW` atau `SETUP`, bukan `BLOCKER`. `BLOCKER` hanya dipakai bila
data live atau invariant yang sudah berlaku saat ini tidak konsisten.

## 2. Contract freeze untuk ODR-2 sampai ODR-6

### Identitas dan idempotency

- satu Sales Order mempunyai identitas Company, Store, Warehouse, Session, dan
  Customer yang immutable setelah Confirm;
- setiap mutation menerima expected `master_version` dan idempotency key;
- retry identik mengembalikan hasil yang sama; payload berbeda pada key yang sama
  ditolak;
- browser tidak memperoleh direct write ke Order, reservation, Dispatch,
  procurement lineage, Payment verification, Stock, FIFO, atau journal.

### Quantity

- seluruh quantity authoritative disimpan dalam base UOM;
- `reserved_open_base_qty = confirmed - canceled - dispatched` per line;
- `available_to_sell = on_hand - reserved_open` per Product-Warehouse;
- total reservation terbuka tidak boleh negatif atau melebihi quantity Order
  yang belum Dispatch;
- partial Dispatch tidak boleh melebihi reservation terbuka.

### Lifecycle

- Confirm/Scheduled membuat reservation tetapi tidak membuat Movement/FIFO/GL;
- Cancel sebelum Dispatch melepaskan reservation;
- Dispatch adalah satu-satunya transition yang mengurangi On Hand/FIFO dan
  menciptakan Movement untuk quantity kirim;
- Delivered tidak mengulang efek Stock atau Finance;
- quantity yang telah Dispatch immutable dan koreksinya memakai Return.

### Procurement

- demand shortage memiliki satu group per Company/Store/Warehouse/Session;
- line demand mempunyai lineage ke reservation/order line;
- Draft PO boleh menerima delta sinkron;
- Confirmed/Partially Received/Received PO tidak diedit otomatis;
- selisih setelah PO final menjadi demand delta atau amendment terkontrol.

### Finance

- order confirmation bukan pengakuan Sale/COGS/Inventory;
- Dispatch membuat event ekonomi Sale/AR/COGS/Inventory;
- verifikasi pembayaran membuat event Cash/Bank/Clearing terhadap AR atau
  Customer Advance;
- pembayaran sebelum Dispatch bukan revenue;
- satu event hanya memiliki satu canonical journal, tetap balance dan period-safe.

## 3. Klasifikasi historical saat cutover

| Data sebelum cutover | Keputusan |
|---|---|
| Sale `POSTED` | Tetap final; tidak dibuat reservation baru dan tidak diposting ulang |
| Delivery `DISPATCHED/DELIVERED` historis | Bukti historis; tidak mengurangi Stock lagi |
| Delivery `READY` milik Sale lama | Legacy-ready; tidak otomatis mengubah Sale lama menjadi Order reserved |
| Draft immediate | Tetap Draft dan baru masuk model ODR lewat aksi user yang tervalidasi |
| Draft scheduled TEMPO | Dipertahankan; conversion ODR-2 wajib eksplisit dan idempotent |
| Movement/FIFO/journal historis | Immutable; hanya direkonsiliasi |
| Request negatif per sesi historis | Dipertahankan dengan source lama; tidak dihitung ulang dari reservation |
| PO Draft | Eligible untuk sync hanya setelah ODR-4 dan lineage berhasil dibuat |
| PO Confirmed/final | Immutable; tidak disentuh backfill |

Tidak ada destructive backfill. Bila sebuah row tidak dapat diklasifikasi secara
aman, migration berikutnya harus berhenti untuk Company tersebut dan melaporkan
row-nya sebagai blocker.

## 4. Failure code minimum

| Domain | Failure code |
|---|---|
| Order | `SALES_ORDER_NOT_FOUND`, `SALES_ORDER_FINAL`, `MASTER_VERSION_CONFLICT` |
| Idempotency | `IDEMPOTENCY_PAYLOAD_CONFLICT` |
| Reservation | `RESERVATION_QUANTITY_EXCEEDED`, `RESERVATION_STATE_MISMATCH` |
| Availability | `INSUFFICIENT_AVAILABLE_STOCK`, `NEGATIVE_STOCK_AUTHORIZATION_REQUIRED` |
| Dispatch | `DELIVERY_NOT_READY`, `DISPATCH_QUANTITY_EXCEEDED`, `DISPATCH_ALREADY_FINAL` |
| FIFO | `FIFO_ALLOCATION_INCOMPLETE`, `STOCK_BALANCE_CONFLICT` |
| Procurement | `DEMAND_LINEAGE_MISSING`, `FINAL_SUPPLIER_ORDER_IMMUTABLE` |
| Payment | `PAYMENT_VERIFICATION_REQUIRED`, `PAYMENT_ALREADY_VERIFIED` |
| Finance | `ACCOUNT_MAPPING_MISSING_OR_AMBIGUOUS`, `ACCOUNTING_PERIOD_NOT_OPEN` |
| Authority | `CUSTOM_PERMISSION_DENIED`, `WAREHOUSE_SCOPE_DENIED`, `ACTIVE_COMPANY_CONTEXT_MISMATCH` |

Pesan UI boleh diterjemahkan, tetapi runtime dan test menggunakan code stabil di
atas agar error tidak disimpulkan dari teks bebas.

## 5. Manifest implementasi berikutnya

ODR-2 wajib bersifat additive dan minimal menyediakan:

- order state serta audit yang memisahkan confirmed order dari posted Sale;
- reservation header/line dengan unique identity dan quantity checks;
- composed read RPC untuk POS/Backoffice tanpa direct table write;
- confirm/edit/cancel core yang transactional dan versioned;
- derived availability read yang tetap kompatibel dengan Stock Real;
- backfill manifest untuk Draft immediate dan Scheduled TEMPO;
- preflight, postflight, behavioral, regression, dan forward-fix note.

Nama relation candidate dalam audit bersifat manifest awal. Nama final boleh
disesuaikan pada ODR-2 selama kontrak dan compatibility di dokumen ini tetap
dipenuhi.
