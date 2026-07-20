# Finance Reporting, Cut-Off, dan Operational Pending Analysis

**Status:** Business/design decision approved; belum menjadi bukti implementasi  
**Scope:** Formula laporan Finance, accounting cut-off, prior-period presentation, reconciliation reports, dan evaluasi Draft/Hold/Pending  
**Dependency:** `FINANCE_CORE_ACCOUNTING_SPEC.md`, `FINANCE_INTEGRATION_NOTES.md`, serta source module terkait

---

## 1. Dua Jenis Laporan yang Tidak Boleh Dicampur

### 1.1 Laporan Keuangan

- Hanya journal/source `POSTED` yang masuk Trial Balance, General Ledger, P&L, Neraca, Cash/Bank, AR/AP, dan Stock Valuation reconciliation.
- Draft, Hold, Pending, Failed, Canceled sebelum posting, dan local queue yang belum acknowledged tidak masuk angka financial.

### 1.2 Laporan Operasional Pending

- User dapat memilih melihat `DRAFT`, `HOLD`, `PENDING`, `WAITING_APPROVAL`, `PENDING_SYNC`, `FAILED`, dan status non-final lain untuk evaluasi operasional.
- Nilai pada laporan ini adalah exposure/potential amount dan wajib diberi label **BELUM MASUK LAPORAN KEUANGAN**.
- Filter status operasional tidak boleh diam-diam ditambahkan ke P&L/Neraca atau total posted.

---

## 2. Timezone, As-Of, dan Cut-Off

- Setiap company memiliki timezone operasional wajib.
- Report menerima `as_of` date/time dan mengubah batas hari/bulan menggunakan timezone company sebelum query accounting date.
- Accounting period tetap bulanan per company.
- Export menyimpan timezone, `as_of`, accounting period, generated timestamp, filter, company, dan report version.
- Store/warehouse dapat berada pada dimension berbeda tetapi mengikuti timezone company pada scope awal; multi-timezone store dibahas bila benar-benar diperlukan.

---

## 3. Accounting Date dan Prior-Period

- Report Finance menggunakan `accounting_date`, bukan Draft creation time.
- `business_event_at`, `original_event_date`, `posted_at`, dan `accounting_date` tetap dapat ditampilkan untuk audit.
- Backdated posting hanya masuk tanggal lama bila period masih `OPEN`.
- Event untuk period `LOCKED` masuk period terbuka berikutnya dengan flag `PRIOR_PERIOD_ADJUSTMENT`, kecuali period lama direopen resmi.
- Prior-period adjustment masuk angka period posting aktual dan ditampilkan terpisah pada GL/P&L/Neraca notes/filter agar tidak menyamarkan keterlambatan.
- Report historis yang diregenerasi setelah official reopen dapat berubah; export lama tetap menyimpan generated/as-of metadata dan tidak dianggap snapshot ledger immutable kecuali fitur report snapshot resmi nanti dibuat.

---

## 4. Formula Laporan Finance

### 4.1 Trial Balance

Per account/dimension:

```text
opening_balance
+ period_debit
- period_credit
= closing_balance
```

Presentation mengikuti normal balance/account type tanpa mengubah nilai journal line. Total Debit dan Credit period wajib seimbang.

### 4.2 General Ledger

- Menampilkan opening, journal line kronologis, running balance, source module/type/id, journal number, actor, dan accounting date.
- Filter minimum: account, date/period, store, warehouse, source module/type, status prior-period, dan reconciliation status.

### 4.3 Profit & Loss

```text
Net Revenue
- COGS
= Gross Profit
- Operating Expense
+/- Other Income/Expense
= Profit/Loss Before Tax-related closing presentation
```

- Grouping laporan berasal dari configurable report mapping/account hierarchy.
- Perubahan grouping tidak mengubah journal historis dan wajib versioned.

### 4.4 Balance Sheet

```text
Assets = Liabilities + Equity
```

- Menampilkan account balance sampai `as_of`.
- Current period profit/loss ditampilkan sebagai equity result/report line sampai closing resmi.

### 4.5 Cash/Bank dan Reconciliation

- Cash/Bank Ledger memakai posted cash/bank/clearing events.
- Menampilkan book balance, reconciled, partially reconciled, unreconciled, clearing, dan reconciliation exception.
- Expected/actual session atau settlement variance tetap report operasional/reconciliation sampai Finance membuat correction event.

### 4.6 AR/AP Aging

- Aging memakai residual open item setelah full/partial reconciliation, bukan original invoice amount.
- Bucket default: current/not due, `1-30`, `31-60`, `61-90`, dan `>90` hari dari due date terhadap `as_of`.
- Collection view boleh memecah `1-30` menjadi `1-7` dan `8-30`; ketika digabung kembali totalnya wajib sama dengan Finance AR Aging. Detail mengikuti `COLLECTION_AND_CUSTOMER_STATEMENT_SPEC.md`.
- Dokumen tanpa due date tampil pada bucket/flag `NO_DUE_DATE`, bukan diasumsikan overdue.
- Banyak payment/invoice tetap mengikuti reconciliation allocation many-to-many.

### 4.7 Stock Valuation Reconciliation

- Inventory subledger menghitung remaining FIFO layer per company/warehouse/product/base UOM pada cut-off.
- Dibandingkan dengan balance account Persediaan GL untuk accounting date yang sama.
- Difference tampil per company/account dan dapat ditelusuri ke source movement/journal.
- Difference tidak otomatis membuat adjustment. Finance/Inventory menyelidiki missing journal, timing, rounding, wrong mapping, atau source correction.

---

## 5. Dimension dan Consolidation

- Satu ledger tetap per company.
- Report default consolidated dalam satu company dan dapat difilter store, warehouse, terminal, session, customer, supplier, category, atau source bila dimension tersedia.
- Filter dimension hanya membagi presentasi; tidak menciptakan ledger baru.
- Data company berbeda tidak dicampur menjadi satu ledger/report accounting. Super Admin boleh melihat overview lintas company sebagai management view dengan pemisahan company yang jelas, bukan consolidated statutory ledger.

---

## 6. Operational Pending Analysis

Data minimum per document/status:

```text
company / store / module
source_type / source_id / document_number
current_status
status_entered_at
age_in_status
created_by
last_action_by / last_action_at
assigned_to_user_or_role nullable
waiting_on_party = CUSTOMER | CASHIER | STORE_MANAGER | FINANCE | SUPPLIER | SYSTEM | NETWORK | STOCK | OTHER | UNKNOWN
delay_reason_code nullable
delay_note nullable
customer_or_supplier nullable
potential_amount nullable
next_action nullable
expected_action_at nullable
```

- `waiting_on_party` tidak boleh disimpulkan hanya dari siapa pembuat dokumen.
- Sistem dapat mengisi otomatis untuk event eksplisit seperti `WAITING_CUSTOMER_PAYMENT`, `WAITING_MANAGER_APPROVAL`, `STOCK_SHORTAGE`, `PENDING_SYNC`, atau `SYSTEM_ERROR`.
- User berwenang dapat mengoreksi klasifikasi dengan alasan dan audit; histori status/assignment tidak dihapus.
- Report menyediakan aging per status, user/role, counterparty, reason, store, module, dan conversion outcome ke Posted/Canceled/Failed.
- Tujuannya membedakan keterlambatan Customer/Supplier dari keterlambatan Cashier/Manager/Finance, kendala stok, jaringan, atau sistem tanpa membuat tuduhan otomatis.
- SLA/target waktu dapat ditambahkan kemudian per module/status; scope awal cukup aging dan expected action optional.

---

## 7. Performance dan Export

- Ledger/source of truth tetap dasar report.
- Daily/monthly summary dapat menjadi rebuildable cache/read model untuk performa dan tidak menggantikan ledger.
- Cache menyimpan source watermark/version dan dapat direbuild per company/period.
- Report berat/export dibuat on-demand, memakai pagination/streaming bila diperlukan, dan tidak dihitung pada setiap dashboard load.
- Export minimum Excel; PDF hanya untuk presentasi yang membutuhkan layout tetap.
- File/export mengikuti retention dan tenant access; jangan menyertakan data company lain.
- Customer Statement tidak disimpan sebagai binary permanen pada scope awal; overdue badge dihitung dari residual/due date tanpa membuat daily reminder row.

---

## 8. Guardrail Implementasi

- Formula dan grouping versioned serta diuji terhadap fixture balanced.
- Jangan menjumlahkan UI total atau cache sebagai sumber final tanpa reconciliation ke ledger.
- Jangan memasukkan non-posted exposure ke angka financial.
- Jangan menghapus historical export/report metadata ketika formula berubah.
- Test minimum: period open/locked, prior-period adjustment, partial AR/AP, multi-store filter, FIFO-vs-GL mismatch, pending aging, timezone boundary, dan cache rebuild.

---

## 9. Decision Log

| Tanggal | Keputusan | Status |
|---|---|---|
| 2026-07-20 | Financial report memakai POSTED saja; non-final tersedia sebagai operational pending report | APPROVED |
| 2026-07-20 | Pending report menganalisis waiting party, reason, actor, status history, dan aging | APPROVED |
| 2026-07-20 | Cut-off memakai company timezone dan as-of metadata | APPROVED |
| 2026-07-20 | Prior-period adjustment masuk current open period dan ditampilkan terpisah | APPROVED |
| 2026-07-20 | Trial Balance/P&L/Neraca memakai versioned report grouping tanpa mengubah journal | APPROVED |
| 2026-07-20 | Stock Valuation membandingkan FIFO subledger dengan Inventory GL tanpa auto-adjust | APPROVED |
| 2026-07-20 | AR/AP Aging memakai residual/due date setelah partial reconciliation | APPROVED |
| 2026-07-20 | Report company consolidated dengan dimension filter; summary cache rebuildable | APPROVED |
