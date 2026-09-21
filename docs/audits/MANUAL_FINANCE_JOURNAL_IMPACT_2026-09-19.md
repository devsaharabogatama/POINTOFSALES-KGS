# Impact Audit — Manual Finance Journal

Status: **LOCAL READY**. Database Production, client deploy, authenticated smoke,
dan UAT belum dijalankan oleh agent.

## Keputusan bisnis yang dikunci

- Jurnal manual dibuat dari tab **Journal Entries** melalui modal.
- Approval per Company dan default **aktif**.
- Saat approval aktif, maker tidak dapat menyetujui jurnalnya sendiri.
- Finance dapat membuat, mengedit, dan submit. Company Admin, Company Owner,
  serta Platform Super Admin dapat approve/post. Accounting hanya melihat.
- Jurnal harus seimbang, minimal dua baris, memakai periode terbuka dan akun COA
  aktif/postable dengan `allow_manual_posting=true`.
- Jurnal POSTED immutable; koreksi memakai jurnal pembalik canonical.

## Impact map

### Direct impact

- `finance_company_policies`: satu flag approval default ON.
- `finance_journals`: metadata workflow manual, referensi, bukti, maker/approver.
- `finance_journal_audit`: tambahan aksi `SAVE_DRAFT`, `SUBMIT`, `APPROVE`.
- Permission baru `finance.manual_journals` dan RPC tenant-scoped/idempotent.
- API Finance Operations dan UI Journal Entries.

### Downstream impact

- General Ledger dan laporan tetap membaca jurnal canonical hanya saat `POSTED`.
- Period lock tetap melihat jurnal canonical `DRAFT`; pending approval tetap
  `DRAFT`, sehingga periode tidak dapat ditutup sebelum diselesaikan.
- Reversal existing tetap dipakai setelah posting.

### Tidak berubah

- Jurnal otomatis, Finance posting queue, Financial Event, POS, Cashier Session,
  payment, Customer/Supplier Receipt, Return/Refund, Stock, Reservation, FIFO,
  Purchase, Sales, dan dokumen sumber.
- Tidak ada transaksi lama yang dihapus atau dihitung ulang. Jurnal MANUAL lama
  hanya mendapat workflow snapshot deterministik sesuai status existing.

## Concurrency, retry, dan audit

- Optimistic `master_version`, row lock, dan advisory lock Company.
- Operation UUID unik per Company; exact retry mengembalikan hasil lama,
  payload berbeda ditolak.
- Server mengulang validasi account, balance, dan periode pada posting boundary.
- Draft/pending dapat dibatalkan dengan alasan; POSTED hanya dapat dibalik.

## Risiko dan batas yang belum dibuktikan

- Production preflight, migration, behavior rollback-only, postflight, dan
  authenticated role smoke masih manual.
- Company tanpa minimal dua COA yang mengizinkan manual posting tidak dapat
  membuat jurnal; UI menjelaskan blocker dan tidak mengubah COA otomatis.
- Rollback schema setelah jurnal manual dipakai tidak aman. Gunakan forward-fix;
  data posted tidak boleh dihapus.
