# Master Metode Pembayaran dan Gateway Fee

**Status:** Business/design decision approved; belum menjadi bukti implementasi  
**Scope:** Master metode pembayaran, store assignment, fee, split payment, settlement, dan reconciliation per company  
**Dependency:** `POS_DEVELOPMENT_NOTES.md`, `FINANCE_CORE_ACCOUNTING_SPEC.md`, `FINANCE_INTEGRATION_NOTES.md`, dan `EXTERNAL_EVIDENCE_LINK_POLICY.md`

---

## 1. Tujuan dan Boundary

Metode pembayaran adalah Master Data reusable per company. Master ini menentukan metode yang dapat dipilih Cashier, lokasi berlakunya, jalur settlement, fee, bukti, dan account function. Master tidak menentukan harga Produk dan tidak mengubah revenue/HPP transaksi.

Scope awal mendukung:

- `CASH`;
- `TRANSFER`;
- `QRIS`;
- `CARD`;
- `E_WALLET`;
- `TEMPO`;
- custom method;
- tender internal yang sudah memiliki kontrak khusus seperti Customer Balance dan Ketul Offset.

Customer Balance dan Ketul Offset tetap mengikuti entitlement/workflow modulnya dan tidak dapat dibuat sebagai custom method untuk melewati kontrol tersebut.

---

## 2. Data Master Minimum

```text
company_id
payment_method_code
payment_method_name
method_type
settlement_route = CASH_DRAWER | DIRECT_BANK | CLEARING | RECEIVABLE | INTERNAL_LIABILITY
status = ACTIVE | INACTIVE
available_all_stores boolean
store_assignments[]
clearing_account_function nullable
bank_account_function nullable
proof_mode = OPTIONAL | REQUIRED
fee_enabled boolean
fee_bearer = COMPANY | CUSTOMER
fee_type = PERCENT | FIXED | PERCENT_PLUS_FIXED
fee_percent nullable
fee_fixed_amount nullable
effective_from
effective_to nullable
created_by / created_at
updated_by / updated_at
```

- `payment_method_code` unik dalam company dan tidak berubah diam-diam setelah dipakai.
- Assignment kosong hanya berarti seluruh store jika `available_all_stores = true`; jangan menafsirkan array kosong secara ambigu.
- Method inactive tidak tersedia untuk transaksi baru, tetapi histori, snapshot, jurnal, dan reconciliation lama tetap dapat dibaca.
- Method yang sudah dipakai tidak dihapus permanen.
- Custom method wajib memilih `settlement_route` dan account function yang kompatibel; label custom tidak boleh menentukan jurnal secara bebas.

---

## 3. Role dan Authority

- Finance, Company Admin, dan Super Admin dapat membuat/mengubah Master Metode Pembayaran sesuai company scope.
- Company Admin dan Super Admin dapat menentukan assignment store; Finance dapat mengelola assignment selama masih dalam company yang sama.
- Cashier hanya memilih metode aktif yang eligible pada store/transaksi dan tidak dapat mengubah fee, account mapping, atau effective date.
- Perubahan master wajib diaudit, versioned, dan hanya berlaku untuk payment baru. Payment historis menyimpan snapshot konfigurasi yang dipakai.
- Super Admin tetap memiliki seluruh authority lintas company melalui workflow resmi, bukan edit langsung jurnal posted.

---

## 4. Fee Rule

Fee dapat berupa:

```text
PERCENT              = payment_leg_base x fee_percent
FIXED                = fee_fixed_amount
PERCENT_PLUS_FIXED   = (payment_leg_base x fee_percent) + fee_fixed_amount
```

- Basis fee adalah nominal payment leg sebelum fee; fee tidak dihitung secara rekursif atas dirinya sendiri.
- Setiap split payment menghitung fee per leg sesuai snapshot metode masing-masing.
- Nilai dibulatkan mengikuti precision currency IDR. Rounding grand total POS tetap aturan terpisah dan tidak boleh dipakai untuk menyembunyikan gateway fee.
- Rule effective-dated. Satu metode/store tidak boleh memiliki rule aktif tumpang-tindih yang menghasilkan resolusi ambigu.
- Jika tersedia company rule dan store-specific rule, store-specific rule yang valid menjadi override.
- POS menampilkan metode, nominal leg, fee, siapa penanggungnya, serta total yang harus dibayar sebelum Cashier mengonfirmasi.

### 4.1 Fee Ditanggung Company

Customer membayar nilai transaksi tanpa tambahan gateway fee. Fee aktual diakui ketika settlement provider/bank diketahui:

```text
Saat sale/payment:
Debit  Payment Clearing (gross)
Credit Penjualan/Piutang sesuai source

Saat settlement:
Debit  Bank (net)
Debit  Biaya Administrasi Bank/Payment Gateway
Credit Payment Clearing (gross)
```

Fee configured adalah expected fee untuk preview/matching. Jurnal memakai fee aktual dari settlement; perbedaan masuk reconciliation exception, bukan diubah otomatis menjadi gain/loss.

### 4.2 Fee Dibebankan kepada Customer

Customer membayar nilai transaksi ditambah surcharge payment. Surcharge tidak menambah harga Produk atau HPP dan ditampilkan terpisah pada checkout/receipt.

```text
Saat sale/payment:
Debit  Payment Clearing (nilai transaksi + surcharge)
Credit Penjualan/Piutang (nilai transaksi)
Credit Pendapatan Penggantian Biaya Pembayaran (surcharge)

Saat settlement:
Debit  Bank (net)
Debit  Biaya Administrasi Bank/Payment Gateway (fee aktual)
Credit Payment Clearing (gross)
```

Company bertanggung jawab memastikan penggunaan customer surcharge sesuai kebijakan operasional dan aturan penyedia pembayaran yang berlaku. Sistem menyimpan fee bearer dan snapshot rule agar laporan tidak mencampurkan surcharge dengan revenue Produk.

---

## 5. Split Payment

- Satu transaksi dapat memiliki beberapa payment leg dari metode berbeda.
- Jumlah nilai settlement leg sebelum customer-borne surcharge harus menutup amount due setelah Customer Balance/Ketul Offset.
- Fee dihitung pada setiap leg, bukan dari total transaksi lalu dibagi secara asumsi.
- Penjualan dan HPP hanya diposting satu kali; payment legs menghasilkan Debit settlement sesuai metode masing-masing.
- Refund menyimpan metode refund aktual. Fee/surcharge refund tidak diasumsikan kembali otomatis; gunakan rule provider dan Credit Note/reconciliation event yang relevan.
- Retry memakai idempotency key payment leg yang sama dan tidak boleh menduplikasi fee atau settlement.

---

## 6. Settlement dan Reconciliation

- `CASH_DRAWER` memengaruhi expected cash sesi.
- `DIRECT_BANK` hanya digunakan jika penerimaan benar-benar verified ke rekening.
- `CLEARING` tetap outstanding sampai settlement provider/bank dicocokkan.
- `RECEIVABLE` dipakai untuk Tempo atau exception yang memang belum dibayar.
- `INTERNAL_LIABILITY` hanya untuk tender internal yang memiliki source ledger sah.
- Settlement dapat many-to-many dan partial sesuai aturan Finance Core.
- Selisih gross, net, expected fee, actual fee, reference, settlement date, dan provider wajib terlihat pada reconciliation.
- Selisih settlement masuk `RECONCILIATION_EXCEPTION`. Finance memilih correction/reclassification resmi; sistem tidak otomatis membukukan selisih menjadi keuntungan atau kerugian.
- Bukti Transfer mengikuti `EXTERNAL_EVIDENCE_LINK_POLICY.md`; URL eksternal tidak menjadi verification otomatis.

---

## 7. Offline

- Offline transaction menyimpan snapshot payment method dan fee rule yang berlaku ketika transaksi diselesaikan lokal.
- Cash mengikuti journal saat sync sebagaimana kontrak POS offline.
- Electronic payment belum verified memakai Piutang Pembayaran Offline, bukan Bank/Clearing seolah dana sudah diterima.
- Customer-borne surcharge yang sudah benar-benar ditagihkan tetap bagian snapshot transaksi.
- Company-borne gateway fee aktual baru diakui ketika settlement tersedia; POS offline tidak menebak actual provider fee.
- Method yang menjadi inactive sebelum sync tetap dapat menyelesaikan transaksi fisik snapshot yang allowance-nya valid, lalu diblokir untuk transaksi baru setelah cache diperbarui.

---

## 8. Guardrail untuk Implementasi

- Seluruh master, assignment, fee rule, payment, dan settlement tenant-scoped.
- Resolver metode/fee berjalan server-side pada transaksi online; POS offline memakai snapshot cache yang ditandatangani/versioned.
- Jangan menyimpan account ID company lain atau menerima account mapping dari client tanpa validasi.
- Jangan menghitung fee hanya di UI.
- Jangan mengubah fee/payment posted melalui UPDATE; gunakan adjustment/reconciliation event append-only.
- Jangan membuat fee provider sebagai potongan tersembunyi terhadap revenue Penjualan.
- List Master memakai pagination/field projection dan cache incremental agar ramah free tier.

---

## 9. Decision Log

| Tanggal | Keputusan | Status |
|---|---|---|
| 2026-07-20 | Metode pembayaran menjadi Master Data company dan dapat berlaku seluruh/store tertentu | APPROVED |
| 2026-07-20 | Cash, Transfer, QRIS, Card, E-Wallet, Tempo, dan custom method didukung | APPROVED |
| 2026-07-20 | Fee mendukung percent, fixed, atau gabungan dengan effective date | APPROVED |
| 2026-07-20 | Fee dapat ditanggung company atau Customer | APPROVED |
| 2026-07-20 | Company-borne fee menjadi Beban Administrasi Payment Gateway saat settlement | APPROVED |
| 2026-07-20 | Split payment menghitung fee per payment leg | APPROVED |
| 2026-07-20 | Cashier hanya memilih; Finance/Company Admin/Super Admin mengatur master dan fee | APPROVED |
| 2026-07-20 | Settlement variance masuk reconciliation exception, bukan auto gain/loss | APPROVED |
