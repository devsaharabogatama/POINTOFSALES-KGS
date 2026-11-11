# Backoffice AR Finance End-to-End Local UAT

Tanggal: 2026-11-10  
Target: Supabase Docker dan Backoffice client lokal. Production dilarang.

## Prasyarat dan bukti

- Company `LOCALBO`, mode `BACKOFFICE_DELIVERED_QTY_INVOICE`, period terbuka.
- User uji memiliki hak Backoffice Sales/Finance.
- Fixture Customer, Product, Warehouse, Stock/FIFO tersedia.
- Migration lokal `20261105100000`, `20261105110000`, `20261105120000`,
  `20261106100000`, `20261110100000`, `20261110110000` terpasang.
- Browser/API menunjuk loopback lokal, bukan hosted Supabase.

Untuk setiap kasus simpan nomor dokumen, status sebelum/sesudah, nominal,
Financial Event/Journal, dan screenshot. Jangan membawa state kasus berikutnya
sebelum hasil kasus aktif dicatat.

## A. Sales Order sampai Invoice

1. Buat SO satu Product dengan harga nonzero, confirm, dan dispatch penuh.
2. Buat Invoice Draft. Buktikan Draft belum membuat Journal dan masih editable.
3. Post Invoice.

Hasil wajib: Stock/FIFO berubah hanya pada tahap fisik; Invoice Posted membuat
debit open item AR dan Journal seimbang (Dr AR, Cr Revenue, plus pajak hanya bila
aktif); exact retry tidak menggandakan hasil; stale version ditolak. Company
lain dan POS Retail tidak berubah.

## B. Penerimaan Customer

### B1. Pelunasan penuh

Buat Receipt sebesar outstanding, alokasikan, lalu post. Harus ada satu Journal
Cash/Bank-to-AR, outstanding nol, lineage Receipt/allocation, tanpa residual
atau Customer Balance otomatis.

### B2. Pembayaran sebagian

Bayar kurang dari outstanding. Outstanding harus berkurang tepat sebesar
alokasi dan sisanya tetap terbuka; tidak boleh auto-allocate ke Invoice lain.

### B3. Pembayaran lebih

Terima lebih dari nilai yang dialokasikan. Satu Journal harus mencatat seluruh
uang diterima; sisa menjadi Customer-scoped Receipt open credit dengan sumber
tertelusur, bukan otomatis Customer Balance atau pembayaran SO/Invoice Draft.

### B4. Tanggal Company

Tanggal bisnis Company hari ini harus diterima walau UTC database berbeda;
tanggal setelah hari Company harus ditolak. Amount, allocation, Journal,
Retail, dan Stock/FIFO tidak boleh berubah karena forward fix ini.

## C. Return dan Credit Note

1. Buat Return dari penjualan Backoffice eligible dan selesaikan penerimaan
   fisik.
2. Buktikan Stock/FIFO/HPP mengikuti canonical Return core dan nilai komersial
   menghasilkan Draft Credit Note.
3. Pilih `Post Credit Note`.

Credit Note harus mengkredit AR penuh dan membuat Customer-scoped open credit,
tanpa automatic refund, Customer Balance, atau Invoice allocation. Tidak boleh
ada Stock/FIFO kedua. Journal harus seimbang dan retry idempotent.

## D. Tindakan eksplisit open credit

### D1. Allocate

Alokasikan partial lalu full ke Invoice Posted Customer yang sama. Cross-
Customer/Company, over-allocation, dan amount di atas outstanding harus ditolak.
Allocation tidak membuat Journal baru karena Journal sumber sudah ada.

### D2. Cash/Bank refund

Refund partial/full dari residual AR-native credit. Journal refund harus
seimbang, sumber tetap tertelusur, retry idempotent, dan Stock/FIFO tetap.

### D3. Customer Balance

Tanpa kebijakan aktif, convert harus ditolak. Bila aktif, convert harus manual,
Customer-scoped, dan tidak terjadi saat Receipt/Credit Note diposting.

### D4. Gunakan Customer Balance

Post Invoice baru lebih dulu lalu gunakan Customer Balance manual. Saldo tidak
boleh menjadi sumber pembayaran SO/Invoice Draft, melebihi saldo/outstanding,
atau dipakai lintas Customer/Company.

### D5. Reversal

Reverse operasi eligible. Reversal wajib append-only, menunjuk operasi asal,
memulihkan residual tepat satu kali, dan exact retry tidak menduplikasi.

## E. Credit Note plus Invoice pengganti

### E1. Aksi atomik

Pada Draft Credit Note native Backoffice non-tax, pilih
`Post & Buat Invoice Pengganti`. Dalam satu transaksi harus terjadi: Credit
Note Posted, allocation ke residual source Invoice, excess tetap open credit,
dan tepat satu replacement Invoice Draft dengan source lineage. Kegagalan satu
langkah membatalkan semua; exact retry sama, changed retry ditolak.

### E2. Draft pengganti

Edit/cancel Draft. Selama Draft tidak boleh ada Stock/FIFO, Payment, Event,
Journal, atau debit open item. Receipt/DP Invoice lama tidak boleh disalin.

### E3. Post pengganti

Post Draft. Harus membuat Event/Journal/open item normal, tanpa duplicate SO qty
counter, dispatch, atau Stock/FIFO. Open credit hanya dipakai manual setelah
Invoice Posted.

## F. Compatibility dan denial matrix

- Plain `Post Credit Note` tetap berfungsi.
- RETAINED_RETAIL/POS Retail tidak masuk replacement Backoffice.
- Legacy Refund Liability dan Posted Journal tidak ditulis ulang.
- Tax-enabled Backoffice Credit Note flow tetap fail-closed.
- Duplicate request, stale version, wrong Customer/Company, dan over-amount
  ditolak tanpa efek parsial.
- Refresh browser harus sama dengan database lokal.

## Kriteria lulus

UAT lokal `PASS` hanya jika seluruh kasus relevan punya bukti, semua Journal
seimbang, tidak ada efek Stock/FIFO/Payment/Finance yang tidak diharapkan,
retry/denial terbukti, dan tidak ada koneksi/mutation Production. Gap
RETAINED_RETAIL wajib tetap dicatat bila fixture eligible belum tersedia.

Setelah UAT lokal, status masih `DATABASE LIVE: LOCAL ONLY`, `CLIENT DEPLOYED:
NO`, dan Production belum boleh disentuh tanpa rollout terpisah.
