"use client";

import { useState, useTransition, type ChangeEvent } from "react";
import type { DashboardData, Month } from "@/lib/data/types";
import { fetchDashboardAction } from "@/app/actions";

/* ------------------------------------------------------------------ */
/* Tema (apresentação — não é dado de negócio)                         */
/* ------------------------------------------------------------------ */
const COLORS = {
  bg: "#0a0e1a",
  panel: "#111726",
  panelBorder: "#1c2438",
  cyan: "#00d4d4",
  green: "#00ff88",
  white: "#ffffff",
  muted: "#8892a4",
  red: "#ff4d6d",
};

/* ------------------------------------------------------------------ */
/* Helpers de formatação (pt-BR)                                       */
/* ------------------------------------------------------------------ */
const brl = (v: number) =>
  v.toLocaleString("pt-BR", { style: "currency", currency: "BRL" });

const num = (v: number) => v.toLocaleString("pt-BR");

const pct = (v: number) =>
  `${v.toLocaleString("pt-BR", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}%`;

/* Marcador de "sem dados" — nunca zera nem inventa número. */
function Na({ small = false }: { small?: boolean }) {
  return (
    <span
      className={small ? "text-[10px]" : "text-xs"}
      style={{ color: COLORS.muted, fontStyle: "italic", fontWeight: 400 }}
    >
      — sem dados ainda
    </span>
  );
}

/* ------------------------------------------------------------------ */
/* Componentes auxiliares                                              */
/* ------------------------------------------------------------------ */
function Panel({
  title,
  children,
  className = "",
}: {
  title?: string;
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <section
      className={`rounded-xl border p-4 ${className}`}
      style={{ background: COLORS.panel, borderColor: COLORS.panelBorder }}
    >
      {title && (
        <h2
          className="mb-3 text-xs font-semibold uppercase tracking-wider"
          style={{ color: COLORS.muted }}
        >
          {title}
        </h2>
      )}
      {children}
    </section>
  );
}

/* Círculo grande do bloco "Provável" */
function StatCircle({
  accent,
  children,
}: {
  accent: string;
  children: React.ReactNode;
}) {
  return (
    <div
      className="flex aspect-square w-40 flex-col items-center justify-center rounded-full border-2 px-4 text-center"
      style={{
        borderColor: accent,
        boxShadow: `0 0 24px ${accent}22, inset 0 0 24px ${accent}11`,
      }}
    >
      {children}
    </div>
  );
}

/* Gauge semicircular em SVG */
function SemiGauge({ value, max }: { value: number | null; max: number }) {
  const has = value != null;
  const frac = has ? Math.min(Math.max(value / max, 0), 1) : 0;
  const r = 90;
  const cx = 110;
  const arc = Math.PI * r; // comprimento do semicírculo
  const offset = arc * (1 - frac);
  const path = `M 20 110 A ${r} ${r} 0 0 1 200 110`;

  return (
    <div className="flex flex-col items-center">
      <svg viewBox="0 0 220 130" className="w-full max-w-[260px]">
        {/* trilho */}
        <path
          d={path}
          fill="none"
          stroke={COLORS.panelBorder}
          strokeWidth={16}
          strokeLinecap="round"
        />
        {/* valor (só quando há dado) */}
        {has && (
          <path
            d={path}
            fill="none"
            stroke={COLORS.green}
            strokeWidth={16}
            strokeLinecap="round"
            strokeDasharray={arc}
            strokeDashoffset={offset}
          />
        )}
        <text
          x={cx}
          y={96}
          textAnchor="middle"
          fontSize={has ? "20" : "12"}
          fontWeight="700"
          fill={has ? COLORS.white : COLORS.muted}
          fontStyle={has ? "normal" : "italic"}
        >
          {has ? brl(value) : "— sem dados ainda"}
        </text>
      </svg>
      <div
        className="mt-1 flex w-full max-w-[260px] justify-between text-xs"
        style={{ color: COLORS.muted }}
      >
        <span>R$ 0</span>
        <span>{`${(max / 1000).toLocaleString("pt-BR", { minimumFractionDigits: 2 })} Mil`}</span>
      </div>
    </div>
  );
}

/* KPI compacto reutilizável */
function MiniKpi({
  label,
  value,
  accent = COLORS.white,
}: {
  label: string;
  value: string | null;
  accent?: string;
}) {
  return (
    <div
      className="flex-1 rounded-lg border px-3 py-2 text-center"
      style={{ background: COLORS.bg, borderColor: COLORS.panelBorder }}
    >
      <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
        {label}
      </div>
      <div className="text-lg font-bold" style={{ color: accent }}>
        {value == null ? <Na small /> : value}
      </div>
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* Dashboard — recebe TODOS os dados via prop (zero hardcode aqui)     */
/* ------------------------------------------------------------------ */
export function Dashboard({
  initialData,
  months,
  initialMonth,
}: {
  initialData: DashboardData;
  months: Month[];
  initialMonth?: string;
}) {
  const [data, setData] = useState<DashboardData>(initialData);
  const [month, setMonth] = useState<string>(initialMonth ?? months[0]?.value ?? "");
  const [isPending, startTransition] = useTransition();

  function onMonthChange(e: ChangeEvent<HTMLSelectElement>) {
    const next = e.target.value;
    setMonth(next);
    startTransition(async () => {
      const d = await fetchDashboardAction(next);
      setData(d);
    });
  }

  const { kpis, provavel, margemGauge, mcMensal, plataformasDre, vendasDiarias } = data;

  return (
    <div className="flex min-h-screen font-sans" style={{ background: COLORS.bg, color: COLORS.white }}>
      {/* ---------- SIDEBAR — Vendas diárias ---------- */}
      <aside
        className="flex w-[220px] shrink-0 flex-col border-r"
        style={{ borderColor: COLORS.panelBorder, background: COLORS.panel }}
      >
        <div className="border-b p-4" style={{ borderColor: COLORS.panelBorder }}>
          <h1 className="text-sm font-bold" style={{ color: COLORS.cyan }}>
            Hub Financeiro
          </h1>
          <p className="mt-0.5 text-xs" style={{ color: COLORS.muted }}>
            Vendas diárias
          </p>
        </div>
        <div className="flex-1 overflow-y-auto p-3">
          <ul className="space-y-2">
            {vendasDiarias.map((v) => (
              <li
                key={v.data}
                className="rounded-lg border p-3"
                style={{ background: COLORS.bg, borderColor: COLORS.panelBorder }}
              >
                <div className="flex items-center justify-between">
                  <span className="text-xs font-semibold" style={{ color: COLORS.cyan }}>
                    {v.data}
                  </span>
                  <span className="text-[11px]" style={{ color: COLORS.muted }}>
                    {num(v.pedidos)} pedidos
                  </span>
                </div>
                <div className="mt-1 text-sm font-bold text-white">{brl(v.valor)}</div>
              </li>
            ))}
          </ul>
        </div>
      </aside>

      {/* ---------- ÁREA PRINCIPAL ---------- */}
      <main className="flex-1 overflow-y-auto p-6">
        {/* TOPO — seletor de mês */}
        <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
          <div>
            <h2 className="text-lg font-bold text-white">Dashboard de Vendas</h2>
            <p className="text-xs" style={{ color: COLORS.muted }}>
              {months.find((m) => m.value === month)?.label ?? "Mês atual"}
            </p>
          </div>
          <div className="flex items-center gap-3">
            {isPending && (
              <span className="text-xs" style={{ color: COLORS.cyan }}>
                Carregando…
              </span>
            )}
            <select
              aria-label="Selecionar mês"
              value={month}
              onChange={onMonthChange}
              disabled={isPending || months.length === 0}
              className="rounded-lg border px-3 py-2 text-sm font-medium outline-none disabled:opacity-60"
              style={{ background: COLORS.panel, borderColor: COLORS.panelBorder, color: COLORS.white }}
            >
              {months.length === 0 && <option value="">Mês atual</option>}
              {months.map((m) => (
                <option key={m.value} value={m.value} style={{ background: COLORS.panel }}>
                  {m.label}
                </option>
              ))}
            </select>
          </div>
        </div>

        {/* conteúdo — esmaece e fica inerte enquanto troca de mês */}
        <div
          style={{
            opacity: isPending ? 0.5 : 1,
            transition: "opacity 150ms ease",
            pointerEvents: isPending ? "none" : "auto",
          }}
        >
          {/* SEÇÃO 1 — KPIs do topo */}
          <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-3">
          <Panel>
            <div className="text-xs uppercase tracking-wider" style={{ color: COLORS.muted }}>
              Total da Venda
            </div>
            <div className="mt-1 text-2xl font-bold" style={{ color: COLORS.green }}>
              {brl(kpis.totalVenda)}
            </div>
          </Panel>
          <Panel>
            <div className="text-xs uppercase tracking-wider" style={{ color: COLORS.muted }}>
              Total de Pedidos
            </div>
            <div className="mt-1 text-2xl font-bold text-white">{num(kpis.totalPedidos)}</div>
          </Panel>
          <Panel>
            <div className="text-xs uppercase tracking-wider" style={{ color: COLORS.muted }}>
              Ticket Médio
            </div>
            <div className="mt-1 text-2xl font-bold" style={{ color: COLORS.cyan }}>
              {brl(kpis.ticketMedio)}
            </div>
          </Panel>
        </div>

        {/* Centro + Direita */}
        <div className="grid grid-cols-1 gap-6 lg:grid-cols-12">
          {/* ----- COLUNA CENTRO ----- */}
          <div className="space-y-6 lg:col-span-7">
            {/* SEÇÃO 2 — Bloco Provável */}
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
                <MiniKpi label="% Ret. L Médio" value={provavel.retLMedio == null ? null : pct(provavel.retLMedio)} accent={COLORS.cyan} />
                <MiniKpi label="% MC L Média" value={provavel.mcLMedia == null ? null : pct(provavel.mcLMedia)} accent={COLORS.green} />
                <MiniKpi label="% MC L Últ Mês" value={provavel.mcLUltMes == null ? null : pct(provavel.mcLUltMes)} accent={COLORS.red} />
              </div>
            </Panel>
          </div>

          {/* ----- COLUNA DIREITA ----- */}
          <div className="space-y-6 lg:col-span-5">
            {/* SEÇÃO 3 — Gauge */}
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

        {/* SEÇÃO 6 — Faixa de plataformas: mini-demonstrativos (full-width) */}
        {/* Dados vêm do provider (data.plataformasDre). Sob DATA_SOURCE=supabase o card
            do Mercado Livre puxa faturamento REAL; deduções/M.C. e as demais plataformas
            ficam null → "sem dados" (RPC de margem travado / sem integração). */}
        <div className="mt-6 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {plataformasDre.map((p) => {
            // MÁSCARA DE EXIBIÇÃO (só a UI): por ora exibimos apenas o Faturamento Bruto.
            // Cancel./Devoluções, Líquido, deduções e M.C. ficam null NA EXIBIÇÃO → "sem
            // dados ainda". O provider/RPC seguem devolvendo os valores intactos; religar
            // depois = apagar este bloco `v` e voltar a usar `p` direto.
            const v = {
              ...p,
              cancelDevolucoes: null,
              faturamentoLiquido: null,
              deducoes: p.deducoes.map((d) => ({ ...d, valor: null })),
              mc: null,
            };
            return (
              <Panel key={v.nome}>
                <div className="flex h-full flex-col">
                  <div className="text-sm font-semibold uppercase tracking-wider text-white">{v.nome}</div>

                  {/* Bloco 1 — Faturamento */}
                  <div className="mt-3 space-y-1 text-xs" style={{ color: COLORS.muted }}>
                    <div className="flex justify-between"><span>Faturamento Bruto</span><span>{v.faturamentoBruto == null ? <Na small /> : brl(v.faturamentoBruto)}</span></div>
                    <div className="flex justify-between"><span>(−) Cancel. e Devoluções</span><span>{v.cancelDevolucoes == null ? <Na small /> : brl(v.cancelDevolucoes)}</span></div>
                  </div>
                  <div
                    className="mt-2 flex justify-between border-t pt-2 text-sm font-bold text-white"
                    style={{ borderColor: COLORS.panelBorder }}
                  >
                    <span>Faturamento Líquido</span><span>{v.faturamentoLiquido == null ? <Na small /> : brl(v.faturamentoLiquido)}</span>
                  </div>

                  {/* Bloco 2 — Deduções */}
                  <div className="mt-3 text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>Deduções</div>
                  <div className="mt-1 space-y-1 text-xs" style={{ color: COLORS.muted }}>
                    {v.deducoes.map((d) => (
                      <div key={d.label} className="flex justify-between pl-3"><span>{d.label}</span><span>{d.valor == null ? <Na small /> : brl(d.valor)}</span></div>
                    ))}
                  </div>

                  {/* Bloco 3 — M.C. (destaque final) */}
                  <div
                    className="mt-3 flex items-center justify-between border-t pt-2 text-base font-bold"
                    style={{ borderColor: COLORS.panelBorder, color: COLORS.green }}
                  >
                    <span>M.C. (Margem de Contribuição)</span><span>{v.mc == null ? <Na small /> : brl(v.mc)}</span>
                  </div>
                </div>
              </Panel>
            );
          })}
        </div>
        </div>
      </main>
    </div>
  );
}
