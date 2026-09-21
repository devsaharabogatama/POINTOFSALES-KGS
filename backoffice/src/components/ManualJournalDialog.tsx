"use client";

import { useMemo, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { Loader2, Plus, Trash2, X } from "lucide-react";
import { userFacingError } from "@/lib/user-facing-error";
import { useEscapeClose } from "@/lib/use-escape-close";

export type ManualJournalAccount = {
  id: string;
  account_code: string;
  account_name: string;
  is_active: boolean;
  allow_manual_posting: boolean;
};

export type ManualJournalLineInput = {
  accountId: string;
  description: string;
  debit: string;
  credit: string;
};

export type EditableManualJournal = {
  id: string;
  accounting_date: string;
  external_reference: string | null;
  evidence_url: string | null;
  description: string;
  master_version: number | string;
};

function emptyLine(): ManualJournalLineInput {
  return { accountId: "", description: "", debit: "", credit: "" };
}

function today() {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
}

async function readJson(response: Response) {
  const text = await response.text();
  if (!text) return {};
  try {
    return JSON.parse(text) as Record<string, unknown>;
  } catch {
    return { error: `HTTP_${response.status}` };
  }
}

export function ManualJournalDialog({
  session,
  accounts,
  journal,
  initialLines,
  approvalRequired,
  close,
  saved,
}: {
  session: Session;
  accounts: ManualJournalAccount[];
  journal: EditableManualJournal | null;
  initialLines: ManualJournalLineInput[];
  approvalRequired: boolean;
  close: () => void;
  saved: (message: string) => Promise<void>;
}) {
  const [accountingDate, setAccountingDate] = useState(
    journal?.accounting_date ?? today(),
  );
  const [externalReference, setExternalReference] = useState(
    journal?.external_reference ?? "",
  );
  const [evidenceUrl, setEvidenceUrl] = useState(journal?.evidence_url ?? "");
  const [description, setDescription] = useState(journal?.description ?? "");
  const [lines, setLines] = useState<ManualJournalLineInput[]>(
    initialLines.length >= 2 ? initialLines : [emptyLine(), emptyLine()],
  );
  const [busy, setBusy] = useState<"SAVE" | "SUBMIT" | null>(null);
  const [error, setError] = useState("");
  const [saveOperationKey] = useState(() => crypto.randomUUID());
  const [submitOperationKey] = useState(() => crypto.randomUUID());
  useEscapeClose(busy ? () => undefined : close);

  const eligibleAccounts = useMemo(
    () =>
      accounts.filter(
        (account) => account.is_active && account.allow_manual_posting,
      ),
    [accounts],
  );
  const totals = useMemo(
    () =>
      lines.reduce(
        (sum, line) => ({
          debit: sum.debit + (Number(line.debit) || 0),
          credit: sum.credit + (Number(line.credit) || 0),
        }),
        { debit: 0, credit: 0 },
      ),
    [lines],
  );

  function updateLine(index: number, patch: Partial<ManualJournalLineInput>) {
    setLines((current) =>
      current.map((line, lineIndex) =>
        lineIndex === index ? { ...line, ...patch } : line,
      ),
    );
  }

  async function persist(submit: boolean) {
    setBusy(submit ? "SUBMIT" : "SAVE");
    setError("");
    try {
      if (!eligibleAccounts.length) {
        throw new Error("Belum ada akun COA yang diizinkan untuk jurnal manual.");
      }
      if (!description.trim()) throw new Error("Keterangan jurnal wajib diisi.");
      if (evidenceUrl && !evidenceUrl.startsWith("https://")) {
        throw new Error("Link bukti harus menggunakan HTTPS.");
      }
      if (
        lines.some(
          (line) =>
            !line.accountId ||
            !(
              (Number(line.debit) > 0 && !Number(line.credit)) ||
              (Number(line.credit) > 0 && !Number(line.debit))
            ),
        )
      ) {
        throw new Error("Setiap baris wajib memilih akun dan mengisi salah satu Debit atau Kredit.");
      }
      if (totals.debit <= 0 || totals.debit !== totals.credit) {
        throw new Error("Total Debit dan Kredit harus sama dan lebih besar dari nol.");
      }
      const saveResponse = await fetch("/api/finance/operations", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${session.access_token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          action: "SAVE_MANUAL_JOURNAL",
          journalId: journal?.id ?? null,
          masterVersion: journal ? Number(journal.master_version) : undefined,
          operationKey: saveOperationKey,
          accountingDate,
          externalReference: externalReference || null,
          evidenceUrl: evidenceUrl || null,
          description,
          lines,
        }),
      });
      const savePayload = await readJson(saveResponse);
      if (!saveResponse.ok) throw new Error(userFacingError(String(savePayload.error ?? "FINANCE_OPERATION_FAILED")));
      const savedJournal = savePayload.data as {
        journalId: string;
        masterVersion: number;
      };
      if (submit) {
        const submitResponse = await fetch("/api/finance/operations", {
          method: "POST",
          headers: {
            Authorization: `Bearer ${session.access_token}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            action: "SUBMIT_MANUAL_JOURNAL",
            journalId: savedJournal.journalId,
            masterVersion: Number(savedJournal.masterVersion),
            operationKey: submitOperationKey,
          }),
        });
        const submitPayload = await readJson(submitResponse);
        if (!submitResponse.ok) throw new Error(userFacingError(String(submitPayload.error ?? "FINANCE_OPERATION_FAILED")));
      }
      await saved(
        submit
          ? approvalRequired
            ? "Jurnal manual berhasil diajukan untuk persetujuan."
            : "Jurnal manual berhasil diposting."
          : "Draft jurnal manual berhasil disimpan.",
      );
      close();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Jurnal manual gagal disimpan.");
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="fixed inset-0 z-[80] grid place-items-center bg-slate-950/55 p-4">
      <section className="flex max-h-[94vh] w-full max-w-6xl flex-col overflow-hidden rounded-3xl bg-white shadow-2xl">
        <header className="flex items-start justify-between border-b border-slate-200 px-6 py-5">
          <div>
            <h2 className="text-xl font-black text-slate-950">
              {journal ? "Edit Jurnal Manual" : "Jurnal Entry Baru"}
            </h2>
            <p className="mt-1 text-sm text-slate-500">
              Approval {approvalRequired ? "aktif: maker dan approver harus berbeda." : "nonaktif: submit langsung posting."}
            </p>
          </div>
          <button onClick={close} disabled={Boolean(busy)} className="rounded-xl p-2 hover:bg-slate-100 disabled:opacity-50" aria-label="Tutup">
            <X className="h-5 w-5" />
          </button>
        </header>
        <div className="overflow-y-auto p-6">
          {error && <div className="mb-5 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm font-bold text-rose-700">{error}</div>}
          <div className="grid gap-4 lg:grid-cols-3">
            <label className="text-sm font-bold text-slate-700">Tanggal akuntansi
              <input type="date" value={accountingDate} onChange={(event) => setAccountingDate(event.target.value)} className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 px-3 font-normal" />
            </label>
            <label className="text-sm font-bold text-slate-700">Referensi eksternal (opsional)
              <input value={externalReference} maxLength={200} onChange={(event) => setExternalReference(event.target.value)} className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 px-3 font-normal" />
            </label>
            <label className="text-sm font-bold text-slate-700">Link bukti HTTPS (opsional)
              <input type="url" value={evidenceUrl} maxLength={2000} placeholder="https://..." onChange={(event) => setEvidenceUrl(event.target.value)} className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 px-3 font-normal" />
            </label>
          </div>
          <label className="mt-4 block text-sm font-bold text-slate-700">Keterangan jurnal
            <textarea value={description} maxLength={1000} rows={3} onChange={(event) => setDescription(event.target.value)} className="mt-2 w-full rounded-xl border border-slate-200 p-3 font-normal" />
          </label>
          <div className="mt-6 overflow-x-auto rounded-2xl border border-slate-200">
            <table className="w-full min-w-[900px] text-sm">
              <thead className="bg-slate-100 text-left text-xs uppercase text-slate-500">
                <tr><th className="px-3 py-3">Akun</th><th className="px-3 py-3">Keterangan</th><th className="px-3 py-3 text-right">Debit</th><th className="px-3 py-3 text-right">Kredit</th><th className="w-12" /></tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {lines.map((line, index) => (
                  <tr key={index}>
                    <td className="p-2"><select value={line.accountId} onChange={(event) => updateLine(index, { accountId: event.target.value })} className="min-h-10 w-full rounded-lg border border-slate-200 px-2"><option value="">Pilih akun</option>{eligibleAccounts.map((account) => <option key={account.id} value={account.id}>{account.account_code} · {account.account_name}</option>)}</select></td>
                    <td className="p-2"><input value={line.description} maxLength={500} onChange={(event) => updateLine(index, { description: event.target.value })} className="min-h-10 w-full rounded-lg border border-slate-200 px-2" /></td>
                    <td className="p-2"><input type="number" min="0" step="0.01" value={line.debit} onChange={(event) => updateLine(index, { debit: event.target.value, credit: event.target.value ? "" : line.credit })} className="min-h-10 w-full rounded-lg border border-slate-200 px-2 text-right" /></td>
                    <td className="p-2"><input type="number" min="0" step="0.01" value={line.credit} onChange={(event) => updateLine(index, { credit: event.target.value, debit: event.target.value ? "" : line.debit })} className="min-h-10 w-full rounded-lg border border-slate-200 px-2 text-right" /></td>
                    <td className="p-2"><button onClick={() => setLines((current) => current.filter((_, lineIndex) => lineIndex !== index))} disabled={lines.length <= 2} className="rounded-lg p-2 text-rose-600 hover:bg-rose-50 disabled:opacity-30" aria-label="Hapus baris"><Trash2 className="h-4 w-4" /></button></td>
                  </tr>
                ))}
              </tbody>
              <tfoot className="bg-slate-50 font-black"><tr><td colSpan={2} className="px-3 py-3 text-right">Total</td><td className="px-3 py-3 text-right">Rp {totals.debit.toLocaleString("id-ID")}</td><td className="px-3 py-3 text-right">Rp {totals.credit.toLocaleString("id-ID")}</td><td /></tr></tfoot>
            </table>
          </div>
          <button onClick={() => setLines((current) => [...current, emptyLine()])} className="mt-3 inline-flex min-h-10 items-center gap-2 rounded-xl border border-slate-200 px-4 text-sm font-black"><Plus className="h-4 w-4" />Tambah baris</button>
        </div>
        <footer className="flex flex-wrap justify-end gap-3 border-t border-slate-200 p-5">
          <button onClick={close} disabled={Boolean(busy)} className="min-h-11 rounded-xl border border-slate-200 px-5 font-black disabled:opacity-50">Batal</button>
          <button onClick={() => void persist(false)} disabled={Boolean(busy)} className="inline-flex min-h-11 items-center gap-2 rounded-xl border border-violet-600 px-5 font-black text-violet-700 disabled:opacity-50">{busy === "SAVE" && <Loader2 className="h-4 w-4 animate-spin" />}Simpan Draft</button>
          <button onClick={() => void persist(true)} disabled={Boolean(busy)} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-violet-600 px-5 font-black text-white disabled:opacity-50">{busy === "SUBMIT" && <Loader2 className="h-4 w-4 animate-spin" />}{approvalRequired ? "Ajukan Persetujuan" : "Simpan & Posting"}</button>
        </footer>
      </section>
    </div>
  );
}
