"use client";

import { useDashboard } from "@/components/DashboardProvider";
import { PlataformaDreCard } from "@/components/PlataformaDreCard";
import {
  COLORS,
  Panel,
  Na,
  StatCircle,
  SemiGauge,
  MiniKpi,
  brl,
  num,
  pct,
} from "@/components/ui";

export default function OverviewPage() {
  const { data } = useDashboard();
  const { kpis, provavel, margemGauge, mcMensal, plataformasDre } = data;

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
              Líquido · todos os canais
            </div>
          </Panel>
          <Panel>
            <div className="text-xs uppercase tracking-wider" style={{ color: COLORS.muted }}>
              MC Total
            </div>
            <div
              className="mt-1 text-2xl font-bold"
              style={{ color: kpis.mcTotal != null && kpis.mcTotal < 0 ? COLORS.red : COLORS.green }}
            >
              {kpis.mcTotal == null ? <Na /> : brl(kpis.mcTotal)}
            </div>
            <div className="mt-0.5 text-[10px]" style={{ color: COLORS.muted }}>
              Soma das M.C. · todos os canais
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

      {/* Centro + Direita */}
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
          <Panel title="Margem de Contribuição Provável">
            <SemiGauge value={margemGauge.valor} max={margemGauge.max} />
            {mcMensal.length === 0 ? (
              <div className="mt-4 text-center">
                <Na />
              </div>
            ) : (
              <div className="mt-4 grid grid-cols-5 gap-2">
                {mcMensal.map((m, i) => (
                  <div
                    key={i}
                    className="rounded-md border px-1 py-2 text-center"
                    style={{ background: COLORS.bg, borderColor: COLORS.panelBorder }}
                  >
                    <div className="text-[10px] font-semibold text-white">
                      {m.valor.toLocaleString("pt-BR", { minimumFractionDigits: 2 })}
                    </div>
                    <div
                      className="mt-1 text-[10px] font-bold"
                      style={{ color: m.pct >= 100 ? COLORS.green : COLORS.cyan }}
                    >
                      {pct(m.pct)}
                    </div>
                  </div>
                ))}
              </div>
            )}
          </Panel>
        </div>
      </div>

      {/* Platform DRE cards */}
      <div className="mt-6 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {plataformasDre.map((p) => (
          <PlataformaDreCard key={p.nome} p={p} />
        ))}
      </div>
    </>
  );
}
