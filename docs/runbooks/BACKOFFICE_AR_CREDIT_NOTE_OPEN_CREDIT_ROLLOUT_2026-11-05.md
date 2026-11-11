# Backoffice AR Credit Note Open Credit — Rollout 2026-11-05

Status: **DATABASE LIVE / FIRST POSTFLIGHT PASS / 3 ROLLBACK BEHAVIORS PASS /
CLOSING POSTFLIGHT PASS / CLIENT N/A / SMOKE+UAT PENDING**.

Closure evidence recorded 2026-11-06: ledger exactly one; runtime, historical,
privilege and business boundaries PASS; all behavior fixtures rolled back; the
closing postflight is identical to the first. Do not rerun or edit migration
`20261105120000`.

## Outcome bisnis

Untuk Company dengan proses `BACKOFFICE_DELIVERED_QTY_INVOICE` dan Tax Sales
tidak aktif:

- Credit Note native Backoffice baru mengkredit AR sebesar seluruh nilai Credit
  Note;
- Credit Note didaftarkan sebagai open credit milik Customer dan Company yang
  sama, tanpa allocation otomatis;
- Invoice sumber tetap mempunyai outstanding sendiri sampai Finance memilih
  tindakan manual pada Task 5;
- tidak ada Cash/Bank refund, Customer Balance, atau Refund Liability baru;
- retained Retail, POS, Stock/FIFO/HPP, dan Credit Note historis tidak diubah.

## Urutan rollout manual

Jalankan file utuh satu per satu. Hentikan pada error atau mandatory `FAIL`:

1. `supabase/diagnostics/backoffice_ar_credit_note_open_credit_preflight.sql`
2. Pastikan state tepat `NOT_INSTALLED`, seluruh dependency/anchor/process/Tax/
   historical/runtime boundary mandatory `PASS`.
3. `supabase/migrations/20261105120000_backoffice_ar_credit_note_open_credit_runtime.sql`
4. `supabase/diagnostics/backoffice_ar_credit_note_open_credit_postflight.sql`
5. `supabase/tests/backoffice_sales_return_credit_note_behavior.sql`
6. `supabase/tests/customer_receipt_credit_note_outstanding_behavior.sql`
7. `supabase/tests/retained_retail_credit_note_refund_bridge_behavior.sql`
8. Jalankan postflight yang sama sekali lagi setelah seluruh rollback behavior.
9. Baru lakukan authenticated smoke dengan Draft baru yang memang disiapkan
   untuk Task 4. Jangan memakai atau mem-post Draft Task 3
   `CR/2026/11/000594`.

Migration tidak boleh dijalankan bila Tax Sales aktif pada Company Backoffice,
Finance queue aktif, Offline submission nonterminal, helper collision, runtime
digest berubah, atau historical Credit Note tidak lagi fully allocated.

## Expected behavior evidence

Behavior utama harus membuktikan dalam satu transaksi rollback:

- native Backoffice Credit Note Posted dengan full AR dan zero Refund Liability;
- Return selesai tanpa status `REFUND_PENDING` baru;
- satu Registry `CREDIT_NOTE` berarah credit, zero allocation, residual penuh;
- source Invoice schedule, payment context, Receipt workspace, receivable helper,
  dan AR open-item tidak mengurangi Invoice sebelum allocation manual;
- AR Aging source Invoice tidak lagi dipotong oleh Credit Note yang belum
  dialokasikan; penyajian baris open credit tersendiri pada report formal tetap
  scope Task 7, sedangkan residual credit sudah terlihat di RPC/panel open-item;
- Customer Statement tetap mencatat Credit Note sebagai credit Customer;
- Journal seimbang dan exact retry tidak menggandakan Event/Journal/Registry;
- retained Retail dispatcher tetap utuh;
- seluruh fixture write di-roll back.

`backoffice_sales_customer_refund_behavior.sql` adalah suite flow lama yang
membuat native Credit Note baru lalu mengharapkan Refund Liability. Expectation
tersebut sengaja tidak berlaku untuk Credit Note Task 4. Suite itu tidak boleh
dipalsukan menjadi PASS; penggantian flow refund open-credit adalah scope Task 5.
Historical Refund dan reversal yang sudah Posted tetap immutable dan tidak
ditulis ulang oleh migration ini.

## Authenticated smoke

Gunakan KMS, LSM, atau SMS dengan Finance user berizin:

1. Buat Return Backoffice baru sampai physical receipt dan alokasi ke Posted
   Invoice menghasilkan Draft Credit Note.
2. Catat outstanding Invoice, panel Penerimaan Customer, AR Aging, dan open-item
   sebelum posting.
3. Post Credit Note sekali.
4. Verifikasi Credit Note full AR, zero Refund Liability, open credit residual
   penuh, satu Event/Journal seimbang, dan source Invoice belum berkurang.
5. Retry operation yang sama dan pastikan tidak ada duplikasi.
6. Jangan apply/refund/convert kredit pada Task 4; action tersebut baru Task 5.
7. Verifikasi retained Retail/POS dan Stock/FIFO tidak berubah.

## Rollback / forward-fix

Migration dibungkus satu transaksi. Guard, patch-anchor, atau postcondition yang
gagal harus me-roll back seluruh perubahan. Sebelum ledger terpasang, kandidat
boleh dikoreksi hanya setelah state diulang dan SOP Gate baru. Setelah ledger
`20261105120000` terpasang, file menjadi immutable: jangan edit, rerun, hapus
ledger, atau rewrite Credit Note historis. Koreksi wajib memakai forward
migration baru setelah impact audit.

Rollback operasional setelah installation bukan drop object. Bekukan posting
Credit Note native Backoffice dan lakukan forward-fix; helper/consumer baru
telah menjadi dependency runtime.

