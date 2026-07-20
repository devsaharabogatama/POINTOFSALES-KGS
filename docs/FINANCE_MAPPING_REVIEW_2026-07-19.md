# Review Final Mapping Finance — 2026-07-19

**Status:** Review desain/dokumentasi; bukan bukti implementasi  
**Scope:** Finance Core, POS, Product/Stock, Purchasing, Expense, Customer Balance, Ketul, serta external evidence  
**Kesimpulan:** Tidak ditemukan konflik fatal pada workflow atau mapping dasar setelah koreksi dokumentasi 2026-07-19.

---

## 1. Dokumen Sumber

1. `FINANCE_CORE_ACCOUNTING_SPEC.md` — ledger, COA, journal, period, reconciliation.
2. `FINANCE_INTEGRATION_NOTES.md` — mapping source event lintas modul.
3. `PRODUCT_STOCK_MASTERDATA_SPEC.md` — stock/FIFO, opname, purchasing operations.
4. `POS_DEVELOPMENT_NOTES.md` — checkout, session, refund, Tempo, offline boundary.
5. `POS_EXPENSE_CASH_FLOW_SPEC.md` — Expense dan drawer movement.
6. `SALES_CUSTOMER_MASTERDATA_SPEC.md` — Customer Balance, Tempo, write-off.
7. `KETUL_WORKFLOW_NOTES.md` — Customer Intake, Transit, Vendor Result/payment.
8. `EXTERNAL_EVIDENCE_LINK_POLICY.md` — bukti/foto external URL.

Review ini tidak membaca schema/code sebagai bukti bahwa desain sudah diimplementasikan.

---

## 2. Hasil Review

### 2.1 Tidak ada konflik fatal

Invariant berikut sudah konsisten:

- satu ledger IDR per company; store/warehouse menjadi dimension;
- semua source document, account, dan journal tenant-scoped;
- automatic journal dibuat server-side dan balanced;
- Draft/Hold/Pending yang belum menjadi business event tidak membuat journal final;
- journal posted immutable; koreksi memakai reversal, Credit/Debit Note, atau replacement;
- stock quantity dan FIFO cost mengikuti source movement yang sama secara atomic;
- Customer Balance, Ketul Offset, dan payment allocation adalah settlement, bukan diskon tersembunyi;
- Finance mapping configurable per company tetapi versioned dan tidak mengubah histori;
- Company Admin memiliki authority Finance dalam company, Super Admin lintas company, tanpa bypass edit langsung journal posted.

### 2.2 Koreksi konflik dokumentasi yang sudah dilakukan

1. Clearing Setor Kas diklasifikasikan sebagai Aset Kas dalam Perjalanan, bukan Kewajiban.
2. Pajak dipecah menjadi entitlement `SALES_TAX` dan `PURCHASE_TAX` yang independen.
3. Gambar/bukti tidak lagi direncanakan upload Supabase Storage pada scope awal; gunakan Google Drive/external URL.
4. Opening cash adalah physical count, bukan journal/Cash In otomatis.
5. Ketul Vendor memakai accrual: Vendor Result confirmed membuat receivable/revenue dan HPP; payment menjadi event terpisah.
6. `NO_PHYSICAL_RETURN` tidak membuat stock-in atau reversal HPP.
7. Pricelist resolved price bukan accounting discount; hanya manual discount memakai contra revenue.
8. Invoice supplier aktual merevaluasi remaining FIFO dan mengoreksi HPP hanya untuk quantity yang sudah terjual.

---

## 3. Mapping Dasar yang Sudah Disetujui

| Source | Debit utama | Kredit utama | Catatan |
|---|---|---|---|
| Sale Cash | Kas Laci | Penjualan | HPP/Inventory ikut diposting |
| Sale electronic pending | Payment Clearing | Penjualan | Clear ke Bank saat verified |
| Sale Tempo | Piutang Customer | Penjualan | Pelunasan tidak repost revenue |
| Manual discount | Retur/Potongan Penjualan | Penjualan | Pricelist bukan discount journal |
| Rounding UP/DOWN | Settlement atau Rounding Loss | Sales/Rounding Gain | Adjustment terlihat terpisah |
| Customer Balance tender | Customer Balance | AR/bagian settlement sale | Mengurangi liability |
| Ketul Offset | Utang Ketul Customer | AR/bagian settlement sale | Bukan diskon |
| Sales Return | Retur Penjualan | AR/Utang Refund | Stock/HPP hanya jika barang kembali |
| Opening Stock | Persediaan | Opening Balance Clearing | Membuat FIFO layer awal |
| Stock Gain | Persediaan | Pendapatan Selisih Stok | Suggested validated cost |
| Stock Loss | Beban Selisih Stok | Persediaan | Mengonsumsi FIFO aktual |
| Goods Receipt | Persediaan | AP Provisional | Accepted quantity saja |
| Supplier Invoice | AP Provisional + variance | AP Final | Remaining vs sold variance dipisah |
| Supplier Payment | AP Final | Bank | Partial/many-to-many |
| Purchase Return | AP/Piutang Refund Supplier | Persediaan | Berdasarkan receipt/FIFO asal |
| Expense disbursement | Outstanding Expense | Kas/Bank | Actual belum final |
| Expense settlement | Expense Category | Outstanding Expense | Return mengurangi outstanding |
| Cash shortage | Piutang Kekurangan Kasir | Kas Laci | Top-up menyelesaikan receivable |
| Cash overage | Kas Laci | Overage Liability | Menunggu resolution Finance |
| Setor Bank | Kas dalam Perjalanan lalu Bank | Kas Laci lalu Kas dalam Perjalanan | Dua tahap/reconciliation |
| Setor kurang | Kas dalam Perjalanan + Under-deposit Control | Kas Laci | Actual ke tujuan; expected dibersihkan penuh |
| Setor lebih | Kas dalam Perjalanan | Kas Laci + Overage Liability | Tidak otomatis menjadi pendapatan |
| Customer Intake Ketul | Persediaan Ketul | Utang Ketul Customer | Membuat FIFO acquisition layer |
| Vendor Result Ketul | Piutang Vendor + HPP Ketul | Penjualan Ketul + Persediaan | Nominal aktual wajib |
| Vendor Payment Ketul | Kas/Bank | Piutang Vendor Ketul | Partial/many-to-many |
| Write-off AR | Beban Piutang Tak Tertagih | Piutang Customer | Maker-checker wajib |
| Recovery | Kas/Bank/Clearing | Recovery Piutang | Tidak membuka AR lama |
| Exceptional Balance Cash | Customer Balance | Kas/Bank | Liability settlement, bukan Expense |
| Exceptional Balance Product | Customer Balance + HPP | Penjualan + Persediaan | Sale/FIFO normal |

Account ID pada tabel adalah fungsi default. Finance/Company Admin/Super Admin dapat memilih account compatible melalui Transaction Rule company dengan version/audit.

---

## 4. Account Template Tambahan yang Sudah Dikunci

- `1250` Piutang Refund Supplier
- `1260` Uang Muka Supplier
- `2140` Utang Ketul kepada Customer
- `2160` Utang Refund Customer
- `2170` Selisih Kas Lebih Belum Diselesaikan
- `2180` Utang/Kredit Vendor Ketul
- `4140` Retur Penjualan Ketul
- `5130` Selisih Harga Beli/HPP
- `6160` Beban Selisih Kas
- `1270` Piutang Pembayaran Offline
- `1280` Selisih Setoran Kurang dalam Investigasi
- `7150` Pendapatan Penggantian Biaya Pembayaran

Kode/nama dapat disesuaikan company. `system_key`, type compatibility, dan fungsi yang sudah dipakai tetap dijaga.

---

## 5. Keputusan yang Masih Terbuka

Ini bukan konflik workflow saat ini, tetapi harus selesai sebelum implementasi area terkait:

1. Faktur pajak resmi/e-Faktur, tax identity/numbering, dan bad-debt tax compliance.
2. Modal dan Aset Tetap tetap deferred.

`OFFLINE_PRICE_VARIANCE`, `OFFLINE_PAYMENT_EXCEPTION`, Master Metode Pembayaran, gateway fee, Tax Engine internal, Purchase matching/tolerance, UOM/weight valuation, Finance report/cut-off, deposit variance resolution, Debit/Credit Note, Transaction Category/account mapping, Bundle revenue allocation, serta Collection/Customer Statement diselesaikan pada 2026-07-20. Open Finance items kini hanya compliance pajak resmi dan Modal/Aset yang memang deferred.

---

## 6. Kebijakan Bukti/Foto

- Cashier mendapat field link bukti Transfer.
- File disimpan sementara di Google Drive; aplikasi menyimpan URL/metadata saja.
- Finance melihat link melalui Backoffice.
- Server tidak mengunduh/proxy file dan link bukan payment verification.
- Storage internal memerlukan keputusan capacity/security terpisah.

---

## 7. Gate Sebelum Implementasi Finance

1. Audit schema production dan data existing; jangan menganggap MD sama dengan schema aktif.
2. Seed Transaction Category/system key registry dan required mapping sesuai kontrak yang disetujui.
3. Buat migration/backfill tanpa langsung mengaktifkan enforcement.
4. Buat error/HOLD queue untuk missing mapping, locked period, dan unbalanced journal.
5. Uji idempotency serta reversal untuk setiap source event.
6. Uji RLS/API authority; menu tersembunyi saja tidak cukup.
7. Jalankan parallel reconciliation stock ledger vs financial inventory dan payment vs cash/bank.
8. Siapkan rollout/rollback dan baru aktifkan posting per company.

Minimum test wajib mencakup Cash sale, Tempo, mixed tender, overdue collection/Promise/due-date correction/Statement, Bundle commercial/component allocation dan partial return, Customer/Supplier Debit-Credit Note full/partial, refund physical/non-physical, Goods Receipt/invoice variance, Purchase Return, Expense advance/return, session variance, Setor Kas matched/under/over dan partial resolution, Ketul partial result/payment, write-off/recovery, dan exceptional Customer Balance settlement.

---

## 8. Verdict

Desain mapping Finance dasar sudah cukup konsisten untuk masuk ke fase taxonomy/source-event contract. Belum aman langsung membuat migration atau mengaktifkan journal production karena open decision pada bagian 5 dan audit schema/code belum dilakukan.
