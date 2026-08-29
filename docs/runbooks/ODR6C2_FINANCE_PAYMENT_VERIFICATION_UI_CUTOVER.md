# ODR-6C.2 Finance Payment Verification UI Cutover

## Status

Local client verification **PASS**. Runtime payment verification, maker-checker,
Cash drawer evidence, Finance Event, controlled dispatcher, dan reconciliation
sudah database-live dari ODR-5D sampai ODR-5F. Tahap ini tidak menambah migration dan
belum dianggap live sebelum authenticated smoke.

## Perubahan

- `Finance -> Verifikasi Bayar` membaca composed RPC canonical, bukan tabel
  payment/Event/Journal langsung.
- User dengan capability `VIEW` dapat melihat permintaan, nominal, Customer,
  Toko, metode pembayaran, waktu pengajuan, dan tautan bukti HTTPS.
- `REVIEW` dapat menolak dan `APPROVE` dapat memverifikasi. Pembuat permintaan
  tidak dapat memutuskan permintaannya sendiri.
- Keputusan memakai optimistic `masterVersion` dan idempotency key stabil.
- Verifikasi hanya membuat Event `HOLD`. Jurnal tetap dibuat melalui
  `Finance -> Posting Queue`; UI tidak mengubah mode Company menjadi automatic.
- Penolakan Cash hanya dapat dilakukan saat sesi Kasir sumber masih terbuka,
  agar reversal drawer tetap exact-once.

## Rollout

1. Jalankan SELECT-only preflight:
   [`odr_phase6c_finance_payment_verification_ui_preflight.sql`](../../supabase/diagnostics/odr_phase6c_finance_payment_verification_ui_preflight.sql).
2. Semua baris selain `INFO` wajib `PASS`.
3. Deploy Backoffice lalu hard refresh.
4. Jalankan authenticated smoke di bawah.
5. Jalankan SELECT-only closing postflight:
   [`odr_phase6c_finance_payment_verification_ui_postflight.sql`](../../supabase/tests/odr_phase6c_finance_payment_verification_ui_postflight.sql).
6. Semua baris selain `INFO` wajib `PASS`.

## Authenticated smoke

1. Buat satu Sales Order dengan payment intent menggunakan user Kasir/UAT.
2. Masuk sebagai Finance/Owner/Admin **yang berbeda dari maker**, lalu buka
   `Finance -> Verifikasi Bayar`.
3. Pastikan Invoice, Customer, Toko, metode, nominal, waktu, dan bukti sesuai.
4. Pastikan maker tidak dapat menekan Verifikasi/Tolak pada permintaannya
   sendiri.
5. Verifikasi satu request non-Cash. Status menjadi `Terverifikasi` dan pesan
   menegaskan event masih `HOLD`.
6. Buka `Posting Queue`, buat preview, periksa event
   `SALE_PAYMENT_VERIFIED`, approve, lalu proses. Jangan lanjut bila preview
   account/amount tidak sesuai.
7. Muat ulang Verifikasi Bayar: request tetap final dan tidak membuat event
   kedua. Periksa jurnal balance melalui queue.
8. Untuk jalur reject, gunakan request UAT terpisah. Cash hanya diuji ketika
   sesi sumber masih OPEN; setelah reject expected drawer harus kembali tepat
   satu kali.
9. Uji pencabutan capability: tanpa `VIEW` endpoint harus menolak dan halaman
   Finance lain tetap dapat dibuka.
10. Jalankan closing postflight.

## Evidence lokal

- Backoffice lint: PASS.
- Backoffice production build dan TypeScript: PASS (77 page/route).
- API memeriksa active Company serta effective capability sebelum RPC.
- Tidak ada migration, direct table write, perubahan policy automatic, atau
  pemrosesan queue otomatis pada tahap UI ini.

## Rollback

Redeploy build Backoffice sebelum cutover. Database tidak memerlukan rollback.
Request yang sudah VERIFIED/REJECTED tetap final dan tidak boleh dikembalikan
melalui UI; koreksi mengikuti Event/Journal source workflow yang berlaku.
