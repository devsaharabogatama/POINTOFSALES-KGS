# Sales Process Cutover Payment Term Boundary — Step 1E-B2/6

Status: LOCAL READY. Database rollout hanya untuk isolated Development
`fkywtxucmyjvpwdiqpix`; production dan staging tidak disentuh.

## Keputusan bisnis yang dikunci

- Retail ke Backoffice mempertahankan `due_date` sumber sebagai satu tanggal
  jatuh tempo absolut; tanggal tidak dihitung ulang saat cutover.
- Backoffice ke Retail hanya boleh mengonversi struktur pembayaran nol atau satu
  jadwal menjadi satu `due_date` absolut.
- SO/Draft Invoice dengan lebih dari satu baris Payment Term/jadwal menjadi
  `BLOCKED` dengan kode `MULTI_INSTALLMENT_MUST_FINISH_IN_BACKOFFICE` dan tetap
  diselesaikan memakai proses sumber.
- Resolver Payment Term target baru boleh berjalan jika target diedit manual
  setelah cutover; converter tidak menjalankan resolver harga/tanggal/term baru.

## Impact map

- Direct: overload classifier dan read-only cutover preview versi 2.
- Downstream: plan yang dibuat/refreshed sesudah migration menyimpan fakta dan
  keputusan versi 2.
- Tidak berubah: dokumen Sales, Invoice, Payment, Stock, Reservation, FIFO,
  Finance, mode Company, permission, dan UI.
- Compatibility: signature classifier 10 argumen tetap tersedia; public preview
  RPC tetap memakai signature yang sama.
- Concurrency: migration berhenti jika ada open plan, Finance queue aktif, atau
  Offline submission nonterminal.

## Urutan manual

1. Jalankan `sales_process_cutover_payment_term_boundary_preflight.sql` utuh.
2. Pastikan tidak ada `BLOCKER` dan identitas server adalah project isolated
   Development.
3. Jalankan migration
   `20260910152000_sales_process_cutover_payment_term_boundary.sql`.
4. Jalankan `sales_process_cutover_payment_term_boundary_behavior.sql` utuh.
5. Jalankan `sales_process_cutover_payment_term_boundary_postflight.sql` utuh.
6. Stop bila behavior bukan `PASS` atau postflight mempunyai `FAIL`.

## Rollback / forward-fix

Migration hanya menambah overload classifier dan mengganti body preview. Belum
ada dokumen operasional atau mode yang dimutasi. Setelah applied, jangan menghapus
ledger atau mengedit migration; lakukan additive forward-fix. Open plan lama
sengaja dilarang agar snapshot keputusan tidak bercampur antara preview v1/v2.

## Evidence yang belum ditutup

- Manual migration/behavior/postflight isolated Development.
- Authenticated Super Admin preview smoke.
- Converter atomik, Apply RPC, UI, production rollout, dan UAT tetap deferred.

