"use client";

import { useState } from "react";
import type { SaidasProjetadas as SaidasProjetadasData } from "@/lib/data/types";
import { COLORS, Panel, brl } from "./ui";

/**
 * Seção "Saídas projetadas" (aba F.C. Projetado).
 *
 * Responde: quanto já está LANÇADO na Omie para sair, e em que dia vence.
 *
 * Três baldes, separados de propósito:
 *  • com data (próximos 90 dias) — o cronograma;
 *  • vencido recente (≤30 dias, ainda em aberto) — exigível agora, entra no total;
 *  • vencido antigo (>30 dias) — título que nunca foi baixado na Omie; NÃO é saída
 *    futura, fica FORA do total mas visível (a confirmar com o financeiro).
 * REGRA DURA: nada estimado — e o que a Omie ainda não tem lançado (folha futura,
 * impostos a apurar, boletos que ainda não chegaram) NÃO aparece. A nota diz isso.
 */

const AMBER = "#ffb84d";

const FAIXAS: { label: string; ate: number | null }[] = [
  { label: "Até 7 dias", ate: 7 },
  { label: "8 a 15 dias", ate: 15 },
  { label: "16 a 30 dias", ate: 30 },
  { label: "31 a 90 dias", ate: null },
];

function difDias(de: string, ate: string): number {
  const a = Date.parse(`${de}T00:00:00Z`);
  const b = Date.parse(`${ate}T00:00:00Z`);
  return Math.round((b - a) / 86400000);
}

function ddmm(data: string): string {
  const [, m, d] = data.split("-");
  return `${d}/${m}`;
}

function Barra({ frac, cor = COLORS.red }: { frac: number; cor?: string }) {
  const f = Math.max(0, Math.min(1, Number.isFinite(frac) ? frac : 0));
  return (
    <div className="h-2 w-full overflow-hidden rounded-full" style={{ background: COLORS.panelBorder }}>
      <div
        className="h-full rounded-full"
        style={{ width: f > 0 ? `max(2px, ${(f * 100).toFixed(2)}%)` : 0, background: cor }}
      />
    </div>
  );
}

function Kpi({
  label,
  valor,
  cor,
  sub,
}: {
  label: string;
  valor: string;
  cor: string;
  sub?: string;
}) {
  return (
    <div className="rounded-lg border px-3 py-2" style={{ borderColor: COLORS.panelBorder, background: COLORS.panel }}>
      <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
        {label}
      </div>
      <div className="text-base font-bold" style={{ color: cor }}>
        {valor}
      </div>
      {sub && (
        <div className="text-[11px]" style={{ color: COLORS.muted }}>
          {sub}
        </div>
      )}
    </div>
  );
}

export function SaidasProjetadas({ dados }: { dados: SaidasProjetadasData | null }) {
  const [cronogramaAberto, setCronogramaAberto] = useState(false);
  const [antigoAberto, setAntigoAberto] = useState(false);

  if (!dados) {
    return (
      <Panel title="Saídas projetadas (Omie — contas a pagar)">
        <p className="text-sm italic" style={{ color: COLORS.muted }}>
          — sem dados ainda
        </p>
      </Panel>
    );
  }

  const { referencia } = dados;
  const faixas = FAIXAS.map(() => 0);
  for (const d of dados.dias) {
    const n = difDias(referencia, d.data);
    const i = FAIXAS.findIndex((f) => f.ate == null || n <= f.ate);
    faixas[i === -1 ? FAIXAS.length - 1 : i] += d.valor;
  }
  const somaFaixas = faixas.reduce((s, v) => s + v, 0);
  const maiorDia = dados.dias.reduce((m, d) => Math.max(m, d.valor), 0);
  const grupos = dados.grupos.filter((g) => g.valor90d > 0 || g.vencidoRecente > 0);
  const maiorGrupo = grupos.reduce((m, g) => Math.max(m, g.valor90d + g.vencidoRecente), 0);
  // "A pagar" = o que tem data nos 90 dias + o vencido recente (exigível agora).
  const aPagar = dados.comData90d + dados.vencidoRecente.valor;

  return (
    <Panel title="Saídas projetadas (Omie — contas a pagar)">
      <div className="rounded-xl border p-4" style={{ background: COLORS.bg, borderColor: COLORS.panelBorder }}>
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
              A pagar — lançado na Omie (próximos 90 dias + vencido recente)
            </div>
            <div className="text-2xl font-bold" style={{ color: COLORS.red }}>
              {brl(aPagar)}
            </div>
          </div>
          <div className="text-right text-xs" style={{ color: COLORS.muted }}>
            <div>
              {dados.titulosComData} títulos em aberto com vencimento futuro · referência {ddmm(referencia)}
            </div>
            {dados.atualizadoEm && <div>contas a pagar sincronizadas {dados.atualizadoEm}</div>}
          </div>
        </div>

        <div className="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-4">
          <Kpi label="Com data (90 dias)" valor={brl(dados.comData90d)} cor={COLORS.white} sub={`${dados.dias.length} datas de vencimento`} />
          <Kpi
            label="Vencido recente (≤30d)"
            valor={brl(dados.vencidoRecente.valor)}
            cor={AMBER}
            sub={
              dados.vencidoRecente.titulos > 0
                ? `${dados.vencidoRecente.titulos} títulos sem baixa, desde ${dados.vencidoRecente.desde ? ddmm(dados.vencidoRecente.desde) : "—"} — exigível agora`
                : "nenhum"
            }
          />
          <Kpi
            label="Após 90 dias"
            valor={brl(dados.apos90d.valor)}
            cor={COLORS.muted}
            sub={dados.apos90d.titulos > 0 ? `${dados.apos90d.titulos} títulos até ${dados.apos90d.ate ? ddmm(dados.apos90d.ate) + "/" + dados.apos90d.ate.slice(0, 4) : "—"} (fora do horizonte)` : "nenhum"}
          />
          <Kpi
            label="Vencido antigo (>30d) — fora"
            valor={brl(dados.vencidoAntigo.valor)}
            cor={COLORS.muted}
            sub={`${dados.vencidoAntigo.titulos} títulos nunca baixados — não entram`}
          />
        </div>

        <div className="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-4">
          {FAIXAS.map((f, i) => (
            <div key={f.label} className="rounded-lg border px-2 py-1.5" style={{ borderColor: COLORS.panelBorder, background: COLORS.panel }}>
              <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
                {f.label}
              </div>
              <div className="mb-1.5 text-sm font-semibold" style={{ color: faixas[i] > 0 ? COLORS.white : COLORS.muted }}>
                {brl(faixas[i])}
              </div>
              <Barra frac={somaFaixas > 0 ? faixas[i] / somaFaixas : 0} />
            </div>
          ))}
        </div>

        <p className="mt-3 text-xs italic" style={{ color: COLORS.muted }}>
          Só o que já está <strong style={{ color: COLORS.white }}>lançado</strong> na Omie (contas a pagar em
          aberto, pelo vencimento da Omie). Despesa que ainda não virou título — folha do mês que vem,
          impostos a apurar, boleto que ainda não chegou — <strong style={{ color: COLORS.white }}>não aparece</strong>.
          O vencido antigo (&gt;30 dias) é título que nunca foi baixado na Omie, não saída futura: fica fora
          do total até o financeiro confirmar.
        </p>
      </div>

      {/* Por grupo (linha do DRE / natureza) */}
      {grupos.length > 0 && (
        <div className="mt-3 rounded-xl border p-4" style={{ background: COLORS.bg, borderColor: COLORS.panelBorder }}>
          <div className="mb-2 flex items-center justify-between">
            <h3 className="text-sm font-bold text-white">Por natureza (90 dias + vencido recente)</h3>
            <span className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
              90 dias · <span style={{ color: AMBER }}>vencido recente</span>
            </span>
          </div>
          <ul className="space-y-1.5">
            {grupos.map((g) => (
              <li key={g.grupo} className="flex items-center gap-2 text-xs">
                <span className="w-[200px] shrink-0 truncate" style={{ color: COLORS.muted }} title={g.grupo}>
                  {g.grupo}
                </span>
                <span className="min-w-0 flex-1">
                  <div className="flex h-2 w-full overflow-hidden rounded-full" style={{ background: COLORS.panelBorder }}>
                    <div style={{ width: maiorGrupo > 0 ? `${((g.valor90d / maiorGrupo) * 100).toFixed(2)}%` : 0, background: COLORS.red }} />
                    <div style={{ width: maiorGrupo > 0 ? `${((g.vencidoRecente / maiorGrupo) * 100).toFixed(2)}%` : 0, background: AMBER }} />
                  </div>
                </span>
                <span className="w-[100px] shrink-0 text-right font-semibold tabular-nums text-white">{brl(g.valor90d)}</span>
                <span className="w-[100px] shrink-0 text-right tabular-nums" style={{ color: g.vencidoRecente > 0 ? AMBER : COLORS.muted }}>
                  {g.vencidoRecente > 0 ? brl(g.vencidoRecente) : "—"}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}

      {/* Cronograma dia a dia */}
      <div className="mt-3 rounded-xl border p-4" style={{ background: COLORS.bg, borderColor: COLORS.panelBorder }}>
        <div className="flex flex-wrap items-center justify-between gap-2 text-xs">
          <span style={{ color: COLORS.muted }}>
            Cronograma por vencimento — {dados.dias.length} {dados.dias.length === 1 ? "data" : "datas"} nos próximos 90 dias
          </span>
          {dados.dias.length > 0 && (
            <button
              type="button"
              onClick={() => setCronogramaAberto((o) => !o)}
              className="rounded-lg border px-2 py-1 transition-colors"
              style={{ color: COLORS.cyan, borderColor: `${COLORS.cyan}44` }}
            >
              {cronogramaAberto ? "Ocultar cronograma" : "Ver cronograma"}
            </button>
          )}
        </div>
        {cronogramaAberto && dados.dias.length > 0 && (
          <ul className="mt-3 space-y-1.5 border-t pt-3" style={{ borderColor: COLORS.panelBorder }}>
            {dados.dias.map((d) => (
              <li key={d.data} className="flex items-center gap-2 text-xs">
                <span className="w-[38px] shrink-0 tabular-nums" style={{ color: COLORS.muted }}>
                  {ddmm(d.data)}
                </span>
                <span className="w-[34px] shrink-0 text-[10px] tabular-nums" style={{ color: `${COLORS.muted}99` }}>
                  D+{Math.max(difDias(referencia, d.data), 0)}
                </span>
                <span className="min-w-0 flex-1">
                  <Barra frac={maiorDia > 0 ? d.valor / maiorDia : 0} />
                </span>
                <span className="w-[44px] shrink-0 text-right text-[10px] tabular-nums" style={{ color: COLORS.muted }}>
                  {d.titulos} tít.
                </span>
                <span className="w-[100px] shrink-0 text-right font-semibold tabular-nums text-white">{brl(d.valor)}</span>
              </li>
            ))}
          </ul>
        )}
      </div>

      {/* Vencido antigo — auditável, não some em silêncio */}
      {dados.vencidoAntigo.titulos > 0 && (
        <div className="mt-3 rounded-xl border p-4" style={{ background: COLORS.bg, borderColor: COLORS.panelBorder, opacity: 0.85 }}>
          <div className="flex flex-wrap items-center justify-between gap-2 text-xs">
            <span style={{ color: COLORS.muted }}>
              <strong style={{ color: COLORS.white }}>{brl(dados.vencidoAntigo.valor)}</strong> em{" "}
              {dados.vencidoAntigo.titulos} títulos vencidos há mais de 30 dias (o mais antigo de{" "}
              {dados.vencidoAntigo.desde ? ddmm(dados.vencidoAntigo.desde) + "/" + dados.vencidoAntigo.desde.slice(0, 4) : "—"}) —{" "}
              <span style={{ color: AMBER }}>fora do total</span>, a confirmar com o financeiro
            </span>
            <button
              type="button"
              onClick={() => setAntigoAberto((o) => !o)}
              className="rounded-lg border px-2 py-1 transition-colors"
              style={{ color: COLORS.cyan, borderColor: `${COLORS.cyan}44` }}
            >
              {antigoAberto ? "Ocultar" : "Ver por fornecedor"}
            </button>
          </div>
          {antigoAberto && (
            <ul className="mt-3 space-y-1 border-t pt-3 text-xs" style={{ borderColor: COLORS.panelBorder }}>
              {dados.vencidoAntigo.fornecedores.map((f) => (
                <li key={f.fornecedor} className="flex items-center justify-between gap-2">
                  <span className="truncate" style={{ color: COLORS.muted }} title={f.fornecedor}>
                    {f.fornecedor}{" "}
                    <span style={{ color: `${COLORS.muted}99` }}>
                      · {f.titulos} tít. · desde {ddmm(f.desde)}/{f.desde.slice(0, 4)}
                    </span>
                  </span>
                  <span className="shrink-0 tabular-nums text-white">{brl(f.valor)}</span>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </Panel>
  );
}
