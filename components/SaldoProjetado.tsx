"use client";

import { useState } from "react";
import type { FcHistorico, Recebiveis, SaidasProjetadas, SaldoCaixa } from "@/lib/data/types";
import { COLORS, Panel, brl } from "./ui";

/**
 * Seção "Saldo projetado por dia" (aba F.C. Projetado).
 *
 * saldo(D) = caixa consolidado hoje (bancos Omie + MP disponível + carteira
 *            Shopee + saques em trânsito — desde 28/08/2026)
 *          + Σ recebíveis COM DATA até D (plataformas integradas que somam)
 *          − Σ saídas COM DATA até D (contas a pagar da Omie)
 *          − vencido recente em D+0 (exigível agora — erro a favor do caixa)
 *
 * Tudo o que NÃO tem data fica FORA da curva e é listado embaixo, com valor:
 * recebível sem data (Shopee em trânsito, Amazon ciclo aberto, SHEIN sem check
 * order, Magalu), plataforma fora do total, saídas após o horizonte, vencido
 * antigo. E o que a Omie ainda não tem lançado não existe aqui — a nota diz isso.
 * Valores vêm da API; única projeção admitida é a do TikTok (Opção B, 25/08/2026:
 * bruto × razão 60d, auto-corrigida pelo statement real — decisão do Luciano).
 *
 * PASSADO (26/08/2026, pedido do Luciano — "estamos falando de fluxo de caixa,
 * precisa bater"): o dia que passou fica no topo da curva com o FLUXO REAL do
 * extrato da Omie: entradas e saídas reais do dia nas contas de caixa
 * (transferência entre duas contas de caixa excluída) e fechamento = saldo de
 * fim de dia — identidade exata fech(D) = fech(D−1) + ent − sai. Dia sem
 * extrato completo cai na foto do fc_snapshot (só movimento líquido).
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
  historico,
}: {
  recebiveis: Recebiveis | null;
  saidas: SaidasProjetadas | null;
  saldo: SaldoCaixa | null;
  historico?: FcHistorico | null;
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

  // Entradas com data: só plataformas integradas que SOMAM (foraDoTotal fica fora).
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

  // HOJE real (26/08/2026, pedido do Luciano): quando o extrato do dia está
  // completo, o D+0 parte do fechamento REAL de ontem e soma o movimento REAL
  // já ocorrido hoje ao projetado restante — pagamento feito de manhã (ex.:
  // boleto previsto p/ ontem pago hoje) aparece nas saídas de hoje.
  const hojeReal = historico?.hoje && historico.hoje.abertura != null ? historico.hoje : null;
  /** Saldo em conta (bancos) na última coleta (card). */
  const saldoConta = saldo?.total ?? null;
  /** Saldo já liberado no Mercado Pago (fechamento do último dia coletado). */
  const mpDisponivel = hojeReal?.mpDisponivel ?? null;
  /** Saldo disponível na carteira Shopee (última transação ingerida, 28/08/2026). */
  const shDisponivel = hojeReal?.shDisponivel ?? null;
  /** Saques MP/Shopee já criados e ainda não caídos no banco. */
  const emTransito = (hojeReal?.mpTransito ?? 0) + (hojeReal?.shTransito ?? 0);
  /** Caixa consolidado de agora: bancos + MP + carteira Shopee + em trânsito. */
  const caixaHoje =
    saldoConta != null ? saldoConta + (mpDisponivel ?? 0) + (shDisponivel ?? 0) + emTransito : null;
  /** Base da curva: abertura CONSOLIDADA de hoje (fechamento de ontem: bancos + MP + Shopee + trânsito); fallback foto. */
  const saldoInicial = hojeReal ? hojeReal.abertura : saldoConta;
  const curva: DiaProj[] = [];
  let acumulado = saldoInicial ?? 0;
  for (let d = 0; d <= horizonte; d++) {
    const data = addDias(referencia, d);
    let e = entradasPorDia.get(data) ?? 0;
    let s = saidasPorDia.get(data) ?? 0;
    if (d === 0 && hojeReal) {
      e += hojeReal.entReal;
      s += hojeReal.saiReal;
    }
    acumulado += e - s;
    curva.push({ data, d, entradas: e, saidas: s, saldo: acumulado });
  }
  // A liberar nas plataformas (destaque do topo): tudo o que já foi vendido e
  // ainda não caiu — só as integradas que somam; com data = tem dia previsto
  // no cronograma (qualquer horizonte), sem data = valorSemData + sem cronograma.
  const aLiberar = somam.reduce((a, p) => a + (p.total ?? 0), 0);
  const aLiberarComData = somam.reduce((a, p) => a + p.dias.reduce((s, d) => s + d.valor, 0), 0);
  const aLiberarSemData = aLiberar - aLiberarComData;
  const totEntradas = curva.reduce((a, x) => a + x.entradas, 0);
  const totSaidas = curva.reduce((a, x) => a + x.saidas, 0);
  const fim = curva[curva.length - 1];
  const minimo = curva.reduce((m, x) => (x.saldo < m.saldo ? x : m), curva[0]);
  const linhas = soMovimento ? curva.filter((x) => x.d === 0 || x.entradas > 0 || x.saidas > 0 || x.d === horizonte) : curva;

  // Passado: dias fechados (fotos de fc_snapshot). Saldo do dia = caixa fechado
  // (foto da manhã seguinte); se ainda não fechou, mostra a abertura.
  const passado = (historico?.dias ?? [])
    .filter((h) => difDias(h.data, referencia) > 0)
    .map((h) => ({ ...h, atras: difDias(h.data, referencia), saldoDia: h.fechamento ?? h.abertura }))
    .sort((a, b) => (a.data < b.data ? -1 : 1));
  const maxAbs = [...curva.map((x) => Math.abs(x.saldo)), ...passado.map((h) => Math.abs(h.saldoDia ?? 0))].reduce(
    (m, v) => Math.max(m, v),
    0,
  );

  // Fora da curva (sem data) — listado com valor, nunca somado.
  const recSemData = somam.reduce((a, p) => a + (p.valorSemData ?? 0), 0);
  const recSemCronograma = somam.filter((p) => p.dias.length === 0).reduce((a, p) => a + (p.total ?? 0), 0);
  const recAlemHorizonte = somam.reduce(
    (a, p) => a + p.dias.filter((d) => difDias(referencia, d.data) > horizonte).reduce((s, d) => s + d.valor, 0),
    0,
  );
  const foraDoTotal = (recebiveis?.plataformas ?? []).filter((p) => p.integrado && p.foraDoTotal);
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

        {/* Saldo inicial + a liberar — destaque no topo (pedido do Luciano 28/08/2026) */}
        <div className="mt-3 grid grid-cols-1 gap-2 sm:grid-cols-2">
          <div className="rounded-lg border px-3 py-2" style={{ borderColor: `${COLORS.cyan}55`, background: COLORS.panel }}>
            <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
              Saldo inicial de hoje ({ddmm(referencia)})
            </div>
            <div className="text-xl font-bold" style={{ color: saldoInicial == null ? COLORS.muted : COLORS.white }}>
              {saldoInicial == null ? "— sem dado" : brl(saldoInicial)}
            </div>
            <div className="text-[11px]" style={{ color: COLORS.muted }}>
              {hojeReal
                ? "abertura do dia = fechamento consolidado de ontem (bancos + MP + Shopee + em trânsito)"
                : "saldo em conta (Omie) — sem fechamento consolidado de ontem"}
            </div>
          </div>
          <div className="rounded-lg border px-3 py-2" style={{ borderColor: `${COLORS.cyan}55`, background: COLORS.panel }}>
            <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
              A liberar nas plataformas
            </div>
            <div className="text-xl font-bold" style={{ color: COLORS.cyan }}>
              {brl(aLiberar)}
            </div>
            <div className="text-[11px]" style={{ color: COLORS.muted }}>
              {`${brl(aLiberarComData)} com data · ${brl(aLiberarSemData)} sem data — vira entrada na curva na data de liberação`}
            </div>
          </div>
        </div>

        <div className="mt-2 grid grid-cols-2 gap-2 sm:grid-cols-4">
          <div className="rounded-lg border px-3 py-2" style={{ borderColor: COLORS.panelBorder, background: COLORS.panel }}>
            <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
              {mpDisponivel != null || shDisponivel != null ? "Caixa hoje (bancos + MP + Shopee)" : "Saldo em conta hoje"}
            </div>
            <div className="text-base font-bold" style={{ color: caixaHoje == null ? COLORS.muted : COLORS.white }}>
              {caixaHoje == null ? "— sem dado" : brl(caixaHoje)}
            </div>
            <div className="text-[11px]" style={{ color: COLORS.muted }}>
              {(mpDisponivel != null || shDisponivel != null) && saldoConta != null
                ? `bancos ${brl(saldoConta)}${saldo?.coletadoEm ? ` (${saldo.coletadoEm})` : ""}` +
                  (mpDisponivel != null
                    ? ` + MP ${brl(mpDisponivel)}${hojeReal?.mpData ? ` (fech. ${ddmm(hojeReal.mpData)})` : ""}`
                    : "") +
                  (shDisponivel != null
                    ? ` + Shopee ${brl(shDisponivel)}${hojeReal?.shData ? ` (${ddmm(hojeReal.shData)})` : ""}`
                    : "") +
                  (emTransito > 0 ? ` + em trânsito p/ banco ${brl(emTransito)}` : "")
                : saldo
                  ? `${saldo.contasCaixa} contas de caixa (Omie)${saldo.coletadoEm ? ` · ${saldo.coletadoEm}` : ""}`
                  : "Omie não coletado"}
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
            Curva dia a dia · abertura · <span style={{ color: COLORS.cyan }}>entradas</span> ·{" "}
            <span style={{ color: COLORS.red }}>saídas</span> · saldo do fim do dia
            {saldoInicial == null && " (sem saldo inicial: a coluna saldo mostra só a variação acumulada)"}
            {passado.length > 0 &&
              " · dias passados: entradas e saídas REAIS do extrato da Omie (contas de caixa, transferências internas excluídas) e caixa fechado no fim do dia"}
            {hojeReal &&
              ` · hoje (D+0): abre no fechamento de ontem e já inclui o movimento REAL do dia (+${brl(hojeReal.entReal)} / −${brl(hojeReal.saiReal)}${hojeReal.coletadoEm ? `, extrato coletado ${hojeReal.coletadoEm}` : ""}) somado ao previsto restante`}
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
          {passado.map((h) => (
            <li key={h.data} className="flex items-center gap-2 text-xs" style={{ opacity: 0.7 }}>
              <span className="w-[38px] shrink-0 tabular-nums" style={{ color: COLORS.muted }}>
                {ddmm(h.data)}
              </span>
              <span className="w-[34px] shrink-0 text-[10px] tabular-nums" style={{ color: `${COLORS.muted}99` }}>
                D−{h.atras}
              </span>
              <span
                className="hidden w-[104px] shrink-0 text-right tabular-nums sm:inline"
                style={{ color: COLORS.muted }}
                title="saldo inicial do dia"
              >
                {h.abertura != null ? brl(h.abertura) : "·"}
              </span>
              <span
                className="w-[96px] shrink-0 text-right tabular-nums"
                style={{
                  color:
                    h.entReal != null
                      ? h.entReal > 0
                        ? COLORS.cyan
                        : `${COLORS.muted}66`
                      : h.movimento != null && h.movimento > 0
                        ? COLORS.cyan
                        : `${COLORS.muted}66`,
                }}
              >
                {h.entReal != null
                  ? h.entReal > 0
                    ? `+${brl(h.entReal)}`
                    : "·"
                  : h.movimento != null && h.movimento > 0
                    ? `+${brl(h.movimento)}`
                    : "·"}
              </span>
              <span
                className="w-[96px] shrink-0 text-right tabular-nums"
                style={{
                  color:
                    h.saiReal != null
                      ? h.saiReal > 0
                        ? COLORS.red
                        : `${COLORS.muted}66`
                      : h.movimento != null && h.movimento < 0
                        ? COLORS.red
                        : `${COLORS.muted}66`,
                }}
              >
                {h.saiReal != null
                  ? h.saiReal > 0
                    ? `−${brl(h.saiReal)}`
                    : "·"
                  : h.movimento != null && h.movimento < 0
                    ? `−${brl(Math.abs(h.movimento))}`
                    : "·"}
              </span>
              <span className="min-w-0 flex-1">
                <div className="h-2 w-full overflow-hidden rounded-full" style={{ background: COLORS.panelBorder }}>
                  <div
                    className="h-full rounded-full"
                    style={{
                      width:
                        maxAbs > 0 && h.saldoDia != null
                          ? `max(2px, ${((Math.abs(h.saldoDia) / maxAbs) * 100).toFixed(2)}%)`
                          : 0,
                      background: h.saldoDia != null ? corSaldo(h.saldoDia) : COLORS.panelBorder,
                    }}
                  />
                </div>
              </span>
              <span
                className="w-[110px] shrink-0 text-right font-semibold tabular-nums"
                style={{ color: h.saldoDia != null ? corSaldo(h.saldoDia) : COLORS.muted }}
                title={
                  h.fechamento != null
                    ? h.fonte === "extrato"
                      ? `caixa fechado no fim do dia (extrato da Omie) · movimento líquido ${h.movimento != null ? brl(h.movimento) : "—"}`
                      : `caixa fechado pela foto de ${h.fechamentoData ? ddmm(h.fechamentoData) : "—"} (abertura ${h.abertura != null ? brl(h.abertura) : "—"})`
                    : "ainda sem fechamento — mostrando a abertura do dia"
                }
              >
                {h.saldoDia != null ? brl(h.saldoDia) : "—"}
                {h.fechamento == null && " *"}
              </span>
            </li>
          ))}
          {passado.length > 0 && (
            <li className="flex items-center gap-2 text-[10px] uppercase tracking-wider" style={{ color: `${COLORS.muted}99` }}>
              <span className="h-px flex-1" style={{ background: COLORS.panelBorder }} />
              <span>hoje — projeção daqui pra frente</span>
              <span className="h-px flex-1" style={{ background: COLORS.panelBorder }} />
            </li>
          )}
          {linhas.map((x) => (
            <li key={x.data} className="flex items-center gap-2 text-xs">
              <span className="w-[38px] shrink-0 tabular-nums" style={{ color: COLORS.muted }}>
                {ddmm(x.data)}
              </span>
              <span className="w-[34px] shrink-0 text-[10px] tabular-nums" style={{ color: `${COLORS.muted}99` }}>
                D+{x.d}
              </span>
              <span
                className="hidden w-[104px] shrink-0 text-right tabular-nums sm:inline"
                style={{ color: `${COLORS.muted}bb` }}
                title="saldo inicial do dia (projetado)"
              >
                {saldoInicial != null ? brl(x.saldo - x.entradas + x.saidas) : "·"}
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
          {foraDoTotal.map((p) => (
            <li key={p.id}>
              <strong style={{ color: COLORS.white }}>{p.total != null ? brl(p.total) : "—"}</strong> {p.nome}: valor fora do
              total consolidado — não entra na curva (o motivo está no card da plataforma).
            </li>
          ))}
          {saidasAlemHorizonte > 0 && (
            <li>
              <strong style={{ color: COLORS.white }}>{brl(saidasAlemHorizonte)}</strong> a pagar com vencimento depois de D+{horizonte}.
            </li>
          )}
          {saidas && saidas.vencidoAntigo.valor > 0 && (
            <li>
              <strong style={{ color: COLORS.white }}>{brl(saidas.vencidoAntigo.valor)}</strong> em títulos vencidos antes de
              ago/2026 na Omie ({saidas.vencidoAntigo.titulos}) — legado nunca baixado, fora da curva por decisão (25/08/2026).
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
            fora: as de marketplace são escriturais/não conciliadas. O saldo DISPONÍVEL do Mercado Pago e da carteira
            Shopee entra no consolidado lido das próprias plataformas (release report / wallet); o que ainda não liberou
            entra pelos recebíveis. Para mudar o que conta como caixa: coluna <code>conta_caixa</code> em{" "}
            <code>omie_saldos_cc</code>.
          </p>
        </div>
      )}
    </Panel>
  );
}
