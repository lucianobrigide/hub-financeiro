"use client";

import { useState } from "react";
import type { Recebiveis, SaidasProjetadas, SaldoCaixa } from "@/lib/data/types";
import { COLORS, Panel, brl } from "./ui";

/**
 * Seção "Saldo projetado por dia" (aba F.C. Projetado).
 *
 * saldo(D) = saldo em conta hoje (Omie, só contas de caixa)
 *          + Σ recebíveis COM DATA até D (plataformas integradas que somam)
 *          − Σ saídas COM DATA até D (contas a pagar da Omie)
 *          − vencido recente em D+0 (exigível agora — erro a favor do caixa)
 *
 * Tudo o que NÃO tem data fica FORA da curva e é listado embaixo, com valor:
 * recebível sem data (Shopee em trânsito, Amazon ciclo aberto, SHEIN sem check
 * order, Magalu), TikTok (fora do total), saídas após o horizonte, vencido antigo.
 * E o que a Omie ainda não tem lançado não existe aqui — a nota diz isso.
 * REGRA DURA: nenhum número da curva é estimado; só soma de fatos com data.
 */

const AMBER = "#ffb84d";
const HORIZONTES = [30, 60, 90] as const;

function difDias(de: string, ate: string): number {
  const a = Date.parse(`${de}T00:00:00Z`);
  const b = Date.parse(`${ate}T00:00:00Z`);
  return Math.round((b - a) / 86400000);
}

function addDias(data: string, n: number): string {
  const t = Date.parse(`${data}T00:00:00Z`) + n * 86400000;
  return new Date(t).toISOString().slice(0, 10);
}

function ddmm(data: string): string {
  const [, m, d] = data.split("-");
  return `${d}/${m}`;
}

interface DiaProj {
  data: string;
  d: number;
  entradas: number;
  saidas: number;
  saldo: number;
}

export function SaldoProjetado({
  recebiveis,
  saidas,
  saldo,
}: {
  recebiveis: Recebiveis | null;
  saidas: SaidasProjetadas | null;
  saldo: SaldoCaixa | null;
}) {
  const [horizonte, setHorizonte] = useState<(typeof HORIZONTES)[number]>(30);
  const [soMovimento, setSoMovimento] = useState(true);

  const referencia = recebiveis?.referencia ?? saidas?.referencia ?? null;
  if (!referencia || (!recebiveis && !saidas)) {
    return (
      <Panel title="Saldo projetado por dia">
        <p className="text-sm italic" style={{ color: COLORS.muted }}>
          — sem dados ainda
        </p>
      </Panel>
    );
  }

  // Entradas com data: só plataformas integradas que SOMAM (TikTok fica fora).
  const somam = (recebiveis?.plataformas ?? []).filter((p) => p.integrado && !p.foraDoTotal);
  const entradasPorDia = new Map<string, number>();
  for (const p of somam) {
    for (const dia of p.dias) {
      // Data já passada (liberação vencida ainda não confirmada) conta em D+0.
      const k = difDias(referencia, dia.data) < 0 ? referencia : dia.data;
      entradasPorDia.set(k, (entradasPorDia.get(k) ?? 0) + dia.valor);
    }
  }
  const saidasPorDia = new Map<string, number>();
  for (const dia of saidas?.dias ?? []) {
    saidasPorDia.set(dia.data, (saidasPorDia.get(dia.data) ?? 0) + dia.valor);
  }
  // Vencido recente (≤30d, sem baixa) = exigível agora → D+0.
  const vencidoRecente = saidas?.vencidoRecente.valor ?? 0;
  if (vencidoRecente > 0) {
    saidasPorDia.set(referencia, (saidasPorDia.get(referencia) ?? 0) + vencidoRecente);
  }

  const saldoInicial = saldo?.total ?? null;
  const curva: DiaProj[] = [];
  let acumulado = saldoInicial ?? 0;
  for (let d = 0; d <= horizonte; d++) {
    const data = addDias(referencia, d);
    const e = entradasPorDia.get(data) ?? 0;
    const s = saidasPorDia.get(data) ?? 0;
    acumulado += e - s;
    curva.push({ data, d, entradas: e, saidas: s, saldo: acumulado });
  }
  const totEntradas = curva.reduce((a, x) => a + x.entradas, 0);
  const totSaidas = curva.reduce((a, x) => a + x.saidas, 0);
  const fim = curva[curva.length - 1];
  const minimo = curva.reduce((m, x) => (x.saldo < m.saldo ? x : m), curva[0]);
  const maxAbs = curva.reduce((m, x) => Math.max(m, Math.abs(x.saldo)), 0);
  const linhas = soMovimento ? curva.filter((x) => x.d === 0 || x.entradas > 0 || x.saidas > 0 || x.d === horizonte) : curva;

  // Fora da curva (sem data) — listado com valor, nunca somado.
  const recSemData = somam.reduce((a, p) => a + (p.valorSemData ?? 0), 0);
  const recSemCronograma = somam.filter((p) => p.dias.length === 0).reduce((a, p) => a + (p.total ?? 0), 0);
  const recAlemHorizonte = somam.reduce(
    (a, p) => a + p.dias.filter((d) => difDias(referencia, d.data) > horizonte).reduce((s, d) => s + d.valor, 0),
    0,
  );
  const tiktok = (recebiveis?.plataformas ?? []).filter((p) => p.integrado && p.foraDoTotal);
  const saidasAlemHorizonte =
    (saidas?.dias ?? []).filter((d) => difDias(referencia, d.data) > horizonte).reduce((s, d) => s + d.valor, 0) +
    (saidas?.apos90d.valor ?? 0);
  const naoIntegradas = (recebiveis?.plataformas ?? []).filter((p) => !p.integrado);
  const contasCaixa = (saldo?.contas ?? []).filter((c) => c.contaCaixa);
  const contasFora = (saldo?.contas ?? []).filter((c) => !c.contaCaixa).length;

  const corSaldo = (v: number) => (v < 0 ? COLORS.red : COLORS.green);

  return (
    <Panel title="Saldo projetado por dia">
      <div className="rounded-xl border p-4" style={{ background: COLORS.bg, borderColor: COLORS.panelBorder }}>
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
              Saldo projetado em D+{horizonte} ({ddmm(fim.data)})
            </div>
            {saldoInicial == null ? (
              <div className="text-lg italic" style={{ color: COLORS.muted }}>
                — sem saldo em conta (Omie) ainda
              </div>
            ) : (
              <div className="text-2xl font-bold" style={{ color: corSaldo(fim.saldo) }}>
                {brl(fim.saldo)}
              </div>
            )}
          </div>
          <div className="flex items-center gap-1 text-xs">
            {HORIZONTES.map((h) => (
              <button
                key={h}
                type="button"
                onClick={() => setHorizonte(h)}
                className="rounded-lg border px-2 py-1 transition-colors"
                style={{
                  color: h === horizonte ? COLORS.bg : COLORS.cyan,
                  background: h === horizonte ? COLORS.cyan : "transparent",
                  borderColor: `${COLORS.cyan}66`,
                }}
              >
                {h} dias
              </button>
            ))}
          </div>
        </div>

        <div className="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-4">
          <div className="rounded-lg border px-3 py-2" style={{ borderColor: COLORS.panelBorder, background: COLORS.panel }}>
            <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
              Saldo em conta hoje
            </div>
            <div className="text-base font-bold" style={{ color: saldoInicial == null ? COLORS.muted : COLORS.white }}>
              {saldoInicial == null ? "— sem dado" : brl(saldoInicial)}
            </div>
            <div className="text-[11px]" style={{ color: COLORS.muted }}>
              {saldo ? `${saldo.contasCaixa} contas de caixa (Omie)${saldo.coletadoEm ? ` · ${saldo.coletadoEm}` : ""}` : "Omie não coletado"}
            </div>
          </div>
          <div className="rounded-lg border px-3 py-2" style={{ borderColor: COLORS.panelBorder, background: COLORS.panel }}>
            <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
              Entradas com data (D+{horizonte})
            </div>
            <div className="text-base font-bold" style={{ color: COLORS.cyan }}>
              {brl(totEntradas)}
            </div>
            <div className="text-[11px]" style={{ color: COLORS.muted }}>
              {somam.length} plataformas que somam
            </div>
          </div>
          <div className="rounded-lg border px-3 py-2" style={{ borderColor: COLORS.panelBorder, background: COLORS.panel }}>
            <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
              Saídas com data (D+{horizonte})
            </div>
            <div className="text-base font-bold" style={{ color: COLORS.red }}>
              {brl(totSaidas)}
            </div>
            <div className="text-[11px]" style={{ color: COLORS.muted }}>
              {vencidoRecente > 0 ? `inclui ${brl(vencidoRecente)} vencido recente em D+0` : "contas a pagar da Omie"}
            </div>
          </div>
          <div className="rounded-lg border px-3 py-2" style={{ borderColor: COLORS.panelBorder, background: COLORS.panel }}>
            <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
              Menor saldo no período
            </div>
            <div className="text-base font-bold" style={{ color: saldoInicial == null ? COLORS.muted : corSaldo(minimo.saldo) }}>
              {saldoInicial == null ? "—" : brl(minimo.saldo)}
            </div>
            <div className="text-[11px]" style={{ color: COLORS.muted }}>
              em {ddmm(minimo.data)} (D+{minimo.d})
            </div>
          </div>
        </div>

        <div className="mt-3 flex flex-wrap items-center justify-between gap-2 text-xs">
          <span style={{ color: COLORS.muted }}>
            Curva dia a dia · <span style={{ color: COLORS.cyan }}>entradas</span> ·{" "}
            <span style={{ color: COLORS.red }}>saídas</span> · saldo
            {saldoInicial == null && " (sem saldo inicial: a coluna saldo mostra só a variação acumulada)"}
          </span>
          <button
            type="button"
            onClick={() => setSoMovimento((o) => !o)}
            className="rounded-lg border px-2 py-1 transition-colors"
            style={{ color: COLORS.cyan, borderColor: `${COLORS.cyan}44` }}
          >
            {soMovimento ? "Mostrar todos os dias" : "Só dias com movimento"}
          </button>
        </div>
        <ul className="mt-2 space-y-1 border-t pt-2" style={{ borderColor: COLORS.panelBorder }}>
          {linhas.map((x) => (
            <li key={x.data} className="flex items-center gap-2 text-xs">
              <span className="w-[38px] shrink-0 tabular-nums" style={{ color: COLORS.muted }}>
                {ddmm(x.data)}
              </span>
              <span className="w-[34px] shrink-0 text-[10px] tabular-nums" style={{ color: `${COLORS.muted}99` }}>
                D+{x.d}
              </span>
              <span className="w-[96px] shrink-0 text-right tabular-nums" style={{ color: x.entradas > 0 ? COLORS.cyan : `${COLORS.muted}66` }}>
                {x.entradas > 0 ? `+${brl(x.entradas)}` : "·"}
              </span>
              <span className="w-[96px] shrink-0 text-right tabular-nums" style={{ color: x.saidas > 0 ? COLORS.red : `${COLORS.muted}66` }}>
                {x.saidas > 0 ? `−${brl(x.saidas)}` : "·"}
              </span>
              <span className="min-w-0 flex-1">
                <div className="h-2 w-full overflow-hidden rounded-full" style={{ background: COLORS.panelBorder }}>
                  <div
                    className="h-full rounded-full"
                    style={{
                      width: maxAbs > 0 ? `max(2px, ${((Math.abs(x.saldo) / maxAbs) * 100).toFixed(2)}%)` : 0,
                      background: corSaldo(x.saldo),
                    }}
                  />
                </div>
              </span>
              <span className="w-[110px] shrink-0 text-right font-semibold tabular-nums" style={{ color: corSaldo(x.saldo) }}>
                {brl(x.saldo)}
              </span>
            </li>
          ))}
        </ul>
      </div>

      {/* Fora da curva — tudo com valor, nada somado */}
      <div className="mt-3 rounded-xl border p-4" style={{ background: COLORS.bg, borderColor: COLORS.panelBorder }}>
        <h3 className="text-sm font-bold text-white">Fora da curva (sem data — não entra em nenhum dia)</h3>
        <ul className="mt-2 space-y-1 text-xs" style={{ color: COLORS.muted }}>
          {recSemData > 0 && (
            <li>
              <strong style={{ color: AMBER }}>{brl(recSemData)}</strong> a receber sem data prevista (cronograma parcial: Shopee
              em trânsito/pré-envio, Amazon ciclo aberto, SHEIN sem check order) — entra no dia em que ganhar data.
            </li>
          )}
          {recSemCronograma > 0 && (
            <li>
              <strong style={{ color: AMBER }}>{brl(recSemCronograma)}</strong> a receber de plataforma sem cronograma (
              {somam.filter((p) => p.dias.length === 0).map((p) => p.nome).join(", ")}).
            </li>
          )}
          {recAlemHorizonte > 0 && (
            <li>
              <strong style={{ color: COLORS.white }}>{brl(recAlemHorizonte)}</strong> a receber com data depois de D+{horizonte}.
            </li>
          )}
          {tiktok.map((p) => (
            <li key={p.id}>
              <strong style={{ color: COLORS.white }}>{p.total != null ? brl(p.total) : "—"}</strong> {p.nome}: bruto pago pelo
              cliente aguardando liquidação — fora do total por decisão (a data existe; o valor final do repasse varia
              e ainda não entra na curva).
            </li>
          ))}
          {saidasAlemHorizonte > 0 && (
            <li>
              <strong style={{ color: COLORS.white }}>{brl(saidasAlemHorizonte)}</strong> a pagar com vencimento depois de D+{horizonte}.
            </li>
          )}
          {saidas && saidas.vencidoAntigo.valor > 0 && (
            <li>
              <strong style={{ color: COLORS.white }}>{brl(saidas.vencidoAntigo.valor)}</strong> em títulos vencidos há mais de 30
              dias na Omie ({saidas.vencidoAntigo.titulos}) — nunca baixados; a confirmar com o financeiro, fora da curva.
            </li>
          )}
          {naoIntegradas.length > 0 && (
            <li>
              Sem integração ainda: {naoIntegradas.map((p) => p.nome).join(", ")} — nada contado.
            </li>
          )}
          <li>
            Despesa que a Omie ainda não tem lançada (folha futura, impostos a apurar, boleto que não chegou) não existe
            aqui. A curva é o que está <strong style={{ color: COLORS.white }}>documentado</strong>, não o caixa inteiro.
          </li>
        </ul>
      </div>

      {/* Contas que compõem o saldo inicial */}
      {saldo && (
        <div className="mt-3 rounded-xl border p-4" style={{ background: COLORS.bg, borderColor: COLORS.panelBorder }}>
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h3 className="text-sm font-bold text-white">Saldo em conta (Omie) — o que conta como caixa</h3>
            <span className="text-xs" style={{ color: COLORS.muted }}>
              conciliado: <strong style={{ color: COLORS.white }}>{brl(saldo.totalConciliado)}</strong>
              {saldo.coletadoEm ? ` · coletado ${saldo.coletadoEm}` : ""}
            </span>
          </div>
          <ul className="mt-2 space-y-1 text-xs">
            {contasCaixa.map((c) => (
              <li key={c.codigo} className="flex items-center justify-between gap-2">
                <span style={{ color: COLORS.muted }}>
                  {c.descricao}
                  <span style={{ color: `${COLORS.muted}99` }}>
                    {" "}
                    · {c.tipo}
                    {c.banco ? ` · banco ${c.banco}` : ""}
                  </span>
                </span>
                <span className="tabular-nums text-white">{c.saldoAtual != null ? brl(c.saldoAtual) : "—"}</span>
              </li>
            ))}
          </ul>
          <p className="mt-2 text-xs italic" style={{ color: COLORS.muted }}>
            Saldo atual (lançado até hoje) das contas correntes de banco real. {contasFora} outras contas da Omie ficam
            fora: as de marketplace (Mercado Livre, Shopee, Amazon…) e a &quot;Mercado Pago&quot; são escriturais/não
            conciliadas — o dinheiro dessas plataformas entra pelos recebíveis, lido delas mesmas. Para mudar o que conta
            como caixa: coluna <code>conta_caixa</code> em <code>omie_saldos_cc</code>.
          </p>
        </div>
      )}
    </Panel>
  );
}
