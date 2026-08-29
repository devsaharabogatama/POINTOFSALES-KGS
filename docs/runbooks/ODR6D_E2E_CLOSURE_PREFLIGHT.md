# ODR-6D Authenticated E2E Closure Preflight

## Tujuan

Menutup arsitektur Order Reservation/Dispatch secara end-to-end tanpa
menganggap empat UI yang berhasil dibuka sebagai bukti seluruh consumer lama
sudah kompatibel. Audit ini SELECT-only dan tidak membuat transaksi.

## Gate

Jalankan:

[`odr_phase6d_e2e_closure_preflight.sql`](../../supabase/diagnostics/odr_phase6d_e2e_closure_preflight.sql)

- `PASS`: invariant database siap.
- `INFO`: inventory saja.
- `SETUP`: wajib dibuktikan lewat authenticated UAT.
- `BLOCKER`: jangan menjalankan UAT final atau mengaktifkan policy baru.

## Consumer compatibility yang diperiksa

1. POS online, Reservation, Invoice/SJ identity, dan Offline fail-closed.
2. Partial/full Dispatch, Stock, FIFO, Movement, dan Event Finance.
3. Demand sesi, managed Stock Request, Draft PO, dan amendment.
4. Payment verification maker-checker, controlled queue, serta Journal.
5. Sales Return terhadap quantity/FIFO yang benar-benar sudah di-Dispatch.
6. AR Aging, Customer Statement, dan Collection TEMPO terhadap receivable ODR
   yang benar-benar sudah diakui saat Dispatch.

## Catatan penting

Source audit lokal menemukan Return dan AR/Collection lama masih berpusat pada
`sales_headers.document_status='POSTED'`, sedangkan Order ODR sengaja tetap
operasional dan mengakui final effect per Dispatch. Karena itu preflight
diperkirakan menampilkan blocker consumer compatibility sampai forward-fix
khusus dibuat. Jangan mengubah Order ODR menjadi legacy `POSTED`: tindakan itu
berisiko membuat Stock, Payment, Event, atau Journal ganda.

## Langkah setelah preflight

1. Kirim seluruh output preflight.
2. Jika blocker hanya pada Return/AR/Collection consumer, kerjakan forward-fix
   additive dengan source Dispatch immutable.
3. Jalankan behavioral dan postflight forward-fix.
4. Baru lakukan UAT matrix lintas dua Company, role denial, retry, stale
   version, negative stock, partial Dispatch, payment, Return, AR, Offline,
   hard refresh, dan rollback rehearsal.

Tidak ada migration atau perubahan data pada tahap preflight ini.

## Evidence lokal

- Backoffice ESLint: PASS.
- Backoffice production build/TypeScript: PASS (77 page/route).
- PWA oxlint: PASS.
- PWA TypeScript/Vite production build: PASS.
- SQL preflight: SELECT-only, delimiter/parentheses seimbang, dan tidak
  mereferensikan relation konseptual.
- Bundle online aktif mengimpor `confirmSalesOrder`; helper final-post legacy
  tetap tersimpan untuk compatibility tetapi tidak dipanggil `App.tsx`.
