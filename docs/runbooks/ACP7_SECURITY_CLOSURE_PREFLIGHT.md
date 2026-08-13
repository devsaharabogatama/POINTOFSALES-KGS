# ACP-7 Security Closure Preflight

ACP-7 menutup custom permission sebelum project kembali ke PRD-1 dan persiapan
Vercel Preview. Tahap ini tidak membuka modul bisnis, tidak mengubah role, dan
tidak menjalankan migration.

## Jalankan

Jalankan seluruh file berikut di Supabase SQL Editor:

`supabase/diagnostics/acp_phase7_security_closure_preflight.sql`

Kirim seluruh output `check_name,status,details`.

## Interpretasi

- `BLOCKER`: hentikan. Invariant live harus diperbaiki sebelum authenticated
  closure matrix.
- `SETUP`: fixture UAT belum lengkap; bukan kerusakan runtime. Lengkapi hanya
  identity/Company/override yang disebutkan.
- `REVIEW`: daftar browser test manual ACP-7 yang memang belum dapat dibuktikan
  dengan SQL.
- `DEFERRED`: build/environment/Vercel diperiksa sesudah SQL dan browser matrix.
- `PASS`: boundary database siap masuk closing matrix.

Tidak perlu membuat data transaksi dummy baru untuk preflight ini. Jangan
menjalankan regression lama satu per satu sebelum output preflight dinilai;
ordered regression suite ACP-7 akan dibekukan setelah fixture live diketahui.
