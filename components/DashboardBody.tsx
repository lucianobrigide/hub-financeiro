"use client";

import type { Kpis, Meta, Provavel, SerieDiariaItem, PlataformaDre } from "@/lib/data/types";
import { PlataformaDreCard } from "./PlataformaDreCard";
import { GraficoDiario } from "./GraficoDiario";
import { GraficoDiarioDetalhado } from "./GraficoDiarioDetalhado";
import { COLORS, Panel, Na, StatCircle, SemiGauge, MiniKpi, brl, num, pct } from "./ui";

export interface DashboardBodyProps {
  kpis: Kpis;
  meta: Meta;
  provavel: Provavel;
  serieDiaria: SerieDiariaItem[];
  cards: { dre: PlataformaDre; href?: string }[];
  /** Rótulo do escopo, ex.: "todos os canais" ou "Mercado Livre". */
  escopo: string;
  tituloGrafico: string;
  /** true nas páginas de canal: gráfico de despesas detalhadas (empilhado). */
  detalharDespesas?: boolean;
}

export function DashboardBody({
  kpis,
  meta,
  provavel,
  serieDiaria,
  cards,
  escopo,
  tituloGrafico,
  detalharDespesas = false,
}: DashboardBodyProps) {
  const mcMeta = meta.mcMeta;
  const mc = kpis.mcTotal;
  const mcTotalPct = mc != null && kpis.totalVenda > 0 ? (mc / kpis.totalVenda) * 100 : null;
  const pctMeta = mcMeta != null && mcMeta > 0 && mc != null ? (mc / mcMeta) * 100 : null;
  const falta = mcMeta != null && mc != null ? Math.round((mcMeta - mc) * 100) / 100 : null;
  const metaBatida = falta != null && falta <= 0;

  return (
    <>
      {/* KPIs */}
      <div className="mb-6 grid grid-cols-1 items-start gap-4 sm:grid-cols-3">
        <div className="flex flex-col gap-4">
          <Panel>
            <div className="text-xs uppercase tracking-wider" style={{ color: COLORS.muted }}>
              Total da Venda
            </div>
            <div className="mt-1 text-2xl font-bold" style={{ color: COLORS.green }}>
              {brl(kpis.totalVenda)}
            </div>
            <div className="mt-0.5 text-[10px]" style={{ color: COLORS.muted }}>
              Líquido · {escopo}
            </div>
          </Panel>
          <Panel>
            <div className="text-xs uppercase tracking-wider" style={{ color: COLORS.muted }}>
              MC Total
            </div>
            <div
              className="mt-1 text-2xl font-bold"
              style={{ color: mc != null && mc < 0 ? COLORS.red : COLORS.green }}
            >
              {mc == null ? (
                <Na />
              ) : (
                <>
                  {brl(mc)}
                  {mcTotalPct != null && (
                    <span className="ml-1.5 text-sm font-semibold">{pct(mcTotalPct)}</span>
                  )}
                </>
              )}
            </div>
            <div className="mt-0.5 text-[10px]" style={{ color: COLORS.muted }}>
              Soma das M.C. · % da venda líquida
            </div>
          </Panel>
        </div>
        <Panel>
          <div className="text-xs uppercase tracking-wider" style={{ color: COLORS.muted }}>
            Total de Pedidos
          </div>
          <div className="mt-1 text-2xl font-bold text-white">{num(kpis.totalPedidos)}</div>
          <div className="mt-0.5 text-[10px]" style={{ color: COLORS.muted }}>
            Válidos · sem cancelados
          </div>
        </Panel>
        <Panel>
          <div className="text-xs uppercase tracking-wider" style={{ color: COLORS.muted }}>
            Ticket Médio
          </div>
          <div className="mt-1 text-2xl font-bold" style={{ color: COLORS.cyan }}>
            {brl(kpis.ticketMedio)}
          </div>
          <div className="mt-0.5 text-[10px]" style={{ color: COLORS.muted }}>
            Venda líquida ÷ pedidos válidos
          </div>
        </Panel>
      </div>

      {/* Provável + Meta */}
      <div className="grid grid-cols-1 gap-6 lg:grid-cols-12">
        <div className="space-y-6 lg:col-span-7">
          <Panel title="Provável">
            <div className="flex flex-wrap items-center justify-center gap-8">
              <StatCircle accent={COLORS.cyan}>
                <div className="text-[10px] uppercase" style={{ color: COLORS.muted }}>
                  Média de Venda Diária
                </div>
                <div className="text-base font-bold" style={{ color: COLORS.cyan }}>
                  {brl(provavel.mediaVendaDiaria)}
                </div>
                <div className="mt-2 text-[10px] uppercase" style={{ color: COLORS.muted }}>
                  Fat. Corrente Provável
                </div>
                <div className="text-sm font-semibold text-white">
                  {brl(provavel.faturamentoCorrenteProvavel)}
                </div>
              </StatCircle>

              <StatCircle accent={COLORS.green}>
                <div className="text-[10px] uppercase" style={{ color: COLORS.muted }}>
                  MC Ideal
                </div>
                <div className="text-base font-bold" style={{ color: COLORS.green }}>
                  {provavel.mcIdeal == null ? <Na small /> : brl(provavel.mcIdeal)}
                </div>
                <div className="mt-2 text-[10px] uppercase" style={{ color: COLORS.muted }}>
                  Ponto de Equilíbrio
                </div>
                <div className="text-sm font-semibold text-white">
                  {provavel.pontoEquilibrio == null ? <Na small /> : brl(provavel.pontoEquilibrio)}
                </div>
                <div className="text-xs font-bold" style={{ color: COLORS.green }}>
                  {provavel.pontoEquilibrioPct == null ? "" : pct(provavel.pontoEquilibrioPct)}
                </div>
              </StatCircle>
            </div>

            <div className="mt-6 flex gap-3">
              <MiniKpi
                label="% Ret. L Médio"
                value={provavel.retLMedio == null ? null : pct(provavel.retLMedio)}
                accent={COLORS.cyan}
              />
              <MiniKpi
                label="% MC L Média"
                value={provavel.mcLMedia == null ? null : pct(provavel.mcLMedia)}
                accent={COLORS.green}
              />
              <MiniKpi
                label="% MC L Últ Mês"
                value={provavel.mcLUltMes == null ? null : pct(provavel.mcLUltMes)}
                accent={COLORS.red}
              />
            </div>
          </Panel>
        </div>

        <div className="space-y-6 lg:col-span-5">
          <Panel title="Meta de M.C.">
            <SemiGauge value={mc} max={mcMeta ?? 220000} />
            <div className="mt-4 space-y-1.5 text-sm">
              <div className="flex items-center justify-between">
                <span style={{ color: COLORS.muted }}>Meta do mês</span>
                <span className="font-semibold text-white">
                  {mcMeta == null ? <Na small /> : brl(mcMeta)}
                </span>
              </div>
              <div className="flex items-center justify-between">
                <span style={{ color: COLORS.muted }}>Atingido</span>
                <span
                  className="font-semibold"
                  style={{ color: metaBatida ? COLORS.green : COLORS.white }}
                >
                  {mc == null ? (
                    <Na small />
                  ) : (
                    `${brl(mc)}${pctMeta == null ? "" : ` · ${pct(pctMeta)}`}`
                  )}
                </span>
              </div>
              <div
                className="flex items-center justify-between border-t pt-1.5"
                style={{ borderColor: COLORS.panelBorder }}
              >
                <span style={{ color: COLORS.muted }}>{metaBatida ? "Excedente" : "Falta"}</span>
                <span
                  className="font-semibold"
                  style={{ color: metaBatida ? COLORS.green : COLORS.cyan }}
                >
                  {falta == null ? <Na small /> : brl(Math.abs(falta))}
                </span>
              </div>
            </div>
          </Panel>
        </div>
      </div>

      {/* Gráfico diário */}
      <div className="mt-6">
        {detalharDespesas ? (
          <GraficoDiarioDetalhado serie={serieDiaria} titulo={tituloGrafico} />
        ) : (
          <GraficoDiario serie={serieDiaria} titulo={tituloGrafico} />
        )}
      </div>

      {/* Cards de DRE por canal */}
      <div className="mt-6 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {cards.map((c) => (
          <PlataformaDreCard key={c.dre.nome} p={c.dre} href={c.href} />
        ))}
      </div>
    </>
  );
}
