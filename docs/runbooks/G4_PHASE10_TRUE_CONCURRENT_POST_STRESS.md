# G4 Phase 10 — True Concurrent Post Stress

## Status

`READY FOR STAGING EXECUTION`

Preflight live telah dikonfirmasi seluruh invariant dan fixture `PASS`.

## Dampak Penting

Harness ini mem-post satu Draft sungguhan, memotong stok/FIFO, membuat Payment,
Movement, audit, receipt, dan Financial Event. Gunakan hanya Draft disposable
di environment staging/development. Jangan jalankan pada transaksi produksi.

Harness mengirim maksimal 20 request Post bersamaan dengan idempotency key yang
sama. Expected result:

- tepat satu response `idempotentReplay=false`;
- seluruh response lain `idempotentReplay=true`;
- hanya satu set Movement, Payment leg, dan POST audit;
- persisted posting key sama dengan key request.

Financial Event tidak dibaca oleh harness karena akun Kasir sengaja tidak
memiliki visibilitas Finance. Coverage Event dibuktikan lewat preflight SQL
server-side setelah stress, bukan dengan memperluas privilege Kasir.

## Persiapan Draft

1. login PWA memakai akun yang akan menjalankan test;
2. buka Session Kasir;
3. buat transaksi Product stok biasa dengan jumlah yang tidak melebihi stok
   aktual pada Gudang penjualan;
4. klik `Simpan Draft`—Draft normal belum dibayar dan tidak perlu mempunyai
   Payment;
5. catat nomor Draft yang terlihat, contoh `DRF-20260729-000001`;
6. jangan Post dari UI dan jalankan harness dalam lima menit agar edit lock
   masih aktif.

Harness otomatis menempelkan satu Payment Method non-proof yang eligible
(memprioritaskan Cash) sebesar total Draft, menyimpan ulang payment intent,
lalu membaca ulang `master_version` authoritative sebelum mengirim Post
concurrent. Ini meniru dua tahap PWA: reprice/save payment intent, kemudian
Post.

Sebelum fan-out, harness membandingkan kebutuhan Base UOM Draft terhadap saldo
`product_stocks`. Fixture yang kekurangan stok dihentikan dengan pesan
`Stress fixture has insufficient stock` dan tidak disamarkan menjadi
`MASTER_VERSION_CONFLICT`.

## Menjalankan

Jalankan dari folder `pwa`. Isi environment variable hanya pada terminal aktif;
jangan menulis password ke repository atau screenshot.

```powershell
$env:G4_TEST_EMAIL='kasir@example.com'
$env:G4_TEST_PASSWORD='password-sementara'
$env:G4_TEST_DRAFT_NO='nomor-draft'
$env:G4_TEST_CONFIRM_POST='YES_POST_STAGING_DRAFT'
$env:G4_TEST_CONCURRENCY='20'
npm.cmd run stress:g4-checkout
```

Company mengikuti Company aktif terakhir akun tersebut di PWA. UUID tidak perlu
dicari atau ditampilkan ke Kasir. Untuk operator teknis yang sengaja ingin
override, `G4_TEST_COMPANY_ID` tetap tersedia sebagai environment variable
opsional.

`VITE_SUPABASE_URL` dan `VITE_SUPABASE_ANON_KEY` dibaca otomatis dari `.env`
PWA bila valid. Nilai placeholder ditolak dan script otomatis fallback ke
`NEXT_PUBLIC_SUPABASE_URL` serta `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` dari
`backoffice/.env.local`, sama seperti development PWA. Bila keduanya tidak
tersedia, set nilai publik tersebut pada terminal aktif.

Setelah selesai, hapus password dari session terminal:

```powershell
Remove-Item Env:G4_TEST_PASSWORD
```

## Output PASS

Kirim JSON output tanpa email, password, access token, atau key. Output tidak
mencetak credential.

Setelah harness PASS:

1. rerun `g4_phase10_online_checkout_stress_preflight.sql`;
2. pastikan seluruh reconciliation tetap `PASS`;
3. lakukan smoke receipt untuk transaksi test;
4. baru lanjut ke contention dua Draft/saldo terbatas atau offline queue sesuai
   gate roadmap berikutnya.

## Boundary

Customer Balance, Ketul Offset, Return/Refund, Expense, Deposit, settlement,
dan offline queue tetap tidak dibuka.
