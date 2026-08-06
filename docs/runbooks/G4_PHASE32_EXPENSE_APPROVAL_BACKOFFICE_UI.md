# G4 Phase 32 — Expense Approval Backoffice UI

## Outcome

Membuka review pengajuan Expense pada `Finance > Approval Expense`. Reviewer
dapat melihat snapshot bisnis lalu approve/reject/cancel melalui RPC Phase 30.
Approval pada fase ini hanya mengubah status dan tidak mencairkan dana.

## Preconditions

- Phase 30 database/postflight/behavior/regression PASS;
- Phase 31 PWA request smoke PASS;
- feature `Expense Operasional` aktif pada Company uji;
- tersedia minimal satu Expense `SUBMITTED` disposable;
- akun reviewer memiliki active Company context yang benar.

## Role Boundary

- Store Manager: review/approve dalam Store scope;
- Company Owner/Admin: review/approve dalam Company;
- Finance: review/approve dalam Company;
- Accounting: read-only;
- Super Admin: seluruh Company sesuai active context;
- pembuat atau Manager/Owner/Admin dapat cancel Draft/Submitted sesuai guard
  server.

UI tidak menjadi sumber authorization. RPC `review_expense_request` dan
`cancel_expense_request` tetap menjadi authority final.

## Authenticated Smoke

1. Restart/hard refresh Backoffice.
2. Buka modul `Finance`, lalu pilih `Approval Expense`.
3. Pastikan tabel menampilkan nomor `EXP-...`, kategori, penanggung jawab,
   Store, nominal, metode pembayaran, dan status—tanpa UUID teknis.
4. Buka detail dan verifikasi:

   - keperluan, penerima, responsible party, target settlement;
   - Session asal dan actor;
   - evidence link dibuka di tab baru;
   - nilai dicairkan/aktual/dikembalikan/outstanding masih nol;
   - `Escape`, backdrop, dan tombol X menutup modal.

5. Approve satu Expense `SUBMITTED`:

   - centang konfirmasi;
   - approval tidak meminta atau mengirim alasan;
   - status berubah menjadi `Disetujui — belum dicairkan`;
   - tidak ada perubahan kas, stock, atau jurnal.

6. Buat pengajuan disposable lain dan reject dengan alasan minimal tiga
   karakter. Pastikan alasan tampil pada detail.
7. Opsional: cancel satu Draft/Submitted disposable dan verifikasi alasan.
8. Login sebagai Accounting: daftar/detail boleh terlihat, tombol approve/
   reject tidak boleh tersedia.
9. Login sebagai role/Store di luar scope: RLS/RPC tidak boleh menampilkan atau
   memproses pengajuan Store lain.

## Automated Evidence

Dari folder `backoffice`:

```powershell
npm.cmd run lint
npm.cmd run build
```

Expected dynamic routes:

```text
/api/finance/expenses
/api/finance/expenses/[id]/review
/api/finance/expenses/[id]/cancel
```

## Compatibility dan Boundary

- Tidak ada migration/schema/grant baru.
- Route memakai user access token, active Company context, RLS, dan guarded RPC;
  tidak memakai service-role dari browser.
- Sale, Return, Payment, Offline queue, Stock, dan PWA request tidak diubah.
- Approval/rejection/cancel tidak membuat disbursement, drawer movement,
  Financial Event final, atau jurnal.
- Disbursement, settlement, Expense Return, Cash In, Offline Expense, Deposit,
  dan G5/G6 tetap tertutup.

## Next Safe Step

Setelah role smoke PASS, lanjut ke SELECT-only preflight disbursement untuk
mengaudit Session/drawer Cash, Transfer confirmation, account function,
idempotency, immutable event, serta reconciliation. Jangan membuka pencairan
hanya dengan direct table write atau client-side calculation.
