# G2 Phase 26 — Product/Category Tax Assignment Preflight

## Tujuan

Mengaudit kesiapan assignment Tax Rule ke Product Category dan override Product
sebelum forward migration/RPC/UI dibuat. Diagnostic ini SELECT-only dan tidak
mengaktifkan resolver atau kalkulasi Tax.

## Jalankan

Jalankan seluruh file berikut di Supabase SQL Editor:

```text
supabase/diagnostics/g2_phase26_tax_assignment_preflight.sql
```

Kirim seluruh hasil `check_name,status,details`.

## Interpretasi

- `BLOCKER`: jangan lanjut migration;
- `REVIEW`: state valid tetapi perlu keputusan/normalisasi sebelum enforcement;
- `PASS`: invariant bersih;
- `INFO`: inventory/privilege/RPC state untuk desain migration.

Expected pada state tanpa assignment:

- dependency PASS;
- assignment invalid/duplicate-current-version PASS;
- assignment inventory dapat nol;
- `enabled_scope_without_eligible_rule` atau
  `active_rule_without_current_version` boleh REVIEW bila entitlement baru
  dinyalakan tetapi Tax Rule aktif belum selesai dibuat;
- `assignment_in_disabled_scope` boleh REVIEW karena konfigurasi assignment
  dapat tetap disimpan ketika modul Tax sementara dimatikan; assignment tersebut
  tidak boleh dipakai resolver selama entitlement nonaktif;
- guarded assignment RPC kemungkinan masih `false`;
- direct Product Category UPDATE kemungkinan masih `true`; ini menjadi input
  untuk menutup direct browser write melalui RPC category yang guarded.

## Boundary Fase Berikutnya

Jika tidak ada blocker, forward migration harus:

1. memvalidasi entitlement, tenant, scope, rule active, dan current effective
   version ketika assignment disimpan;
2. menyediakan atomic optimistic-concurrency RPC Category assignment;
3. menjaga Product + Product-UOM + Tax override tetap satu transaksi atomic;
4. mengaudit before/after assignment;
5. tidak mengaktifkan resolver, checkout calculation, Purchase Invoice Tax,
   posting, atau report;
6. menyediakan postflight dan negative behavioral tests.
