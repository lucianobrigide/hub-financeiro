"use client";

import {
  Bar,
  CartesianGrid,
  ComposedChart,
  Line,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";

/* ------------------------------------------------------------------ */
/* Tema                                                                */
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

/* ------------------------------------------------------------------ */
/* Dados hardcoded                                                     */
/* ------------------------------------------------------------------ */
const KPIS = {
  totalVenda: 20641882.07,
  totalPedidos: 108104,
  ticketMedio: 190.94,
};

const PROVAVEL = {
  mediaVendaDiaria: 110754.17,
  faturamentoCorrenteProvavel: 3322624.99,
  mcIdeal: 195000.0,
  pontoEquilibrio: 3902813.43,
  pontoEquilibrioPct: 85.13,
  retLMedio: 10.0,
  mcLMedia: 6.98,
  mcLUltMes: 5.0,
};

const GAUGE = {
  valor: 166011.49,
  max: 214500, // R$ 214,50 Mil
};

const MC_MENSAL = [
  { valor: 351929.16, pct: 113.19 },
  { valor: 298943.15, pct: 84.18 },
  { valor: 348283.12, pct: 98.08 },
  { valor: 322421.66, pct: 90.79 },
  { valor: 166011.49, pct: 85.13 },
];

// Total Mensal — venda em milhões; percentuais de MC
const TOTAL_MENSAL = [
  { mes: "Fev/26", venda: 2.55, mcVenda: 13.78, mcLiquida: 8.8 },
  { mes: "Mar/26", venda: 2.3, mcVenda: 12.97, mcLiquida: 7.01 },
  { mes: "Abr/26", venda: 2.41, mcVenda: 14.45, mcLiquida: 7.51 },
  { mes: "Mai/26", venda: 2.77, mcVenda: 11.65, mcLiquida: 6.34 },
  { mes: "Jun/26", venda: 2.49, mcVenda: 6.67, mcLiquida: 5.0 },
];

const PLATAFORMAS = [
  { nome: "Mercado Livre", valor: 18766989.48 },
  { nome: "Shopee", valor: 1074496.25 },
  { nome: "Tik Tok", valor: 796985.74 },
  { nome: "Amazon", valor: 2191.1 },
  { nome: "Vendas Internas", valor: 1219.5 },
];

const VENDAS_DIARIAS = [
  { data: "15/06", valor: 206708.39, pedidos: 1060 },
  { data: "14/06", valor: 176214.45, pedidos: 913 },
  { data: "13/06", valor: 138011.13, pedidos: 709 },
  { data: "12/06", valor: 227073.48, pedidos: 1151 },
  { data: "11/06", valor: 248764.08, pedidos: 1276 },
  { data: "10/06", valor: 199062.39, pedidos: 1034 },
];

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
function SemiGauge({ value, max }: { value: number; max: number }) {
  const frac = Math.min(Math.max(value / max, 0), 1);
  const r = 90;
  const cx = 110;
  const cy = 110;
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
        {/* valor */}
        <path
          d={path}
          fill="none"
          stroke={COLORS.green}
          strokeWidth={16}
          strokeLinecap="round"
          strokeDasharray={arc}
          strokeDashoffset={offset}
        />
        <text
          x={cx}
          y={96}
          textAnchor="middle"
          fontSize="20"
          fontWeight="700"
          fill={COLORS.white}
        >
          {brl(value)}
        </text>
      </svg>
      <div
        className="mt-1 flex w-full max-w-[260px] justify-between text-xs"
        style={{ color: COLORS.muted }}
      >
        <span>R$ 0</span>
        <span>R$ 214,50 Mil</span>
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
  value: string;
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
        {value}
      </div>
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* Tooltip custom do gráfico                                           */
/* ------------------------------------------------------------------ */
type TooltipItem = { name: string; value: number; color: string };
function ChartTooltip({
  active,
  payload,
  label,
}: {
  active?: boolean;
  payload?: TooltipItem[];
  label?: string;
}) {
  if (!active || !payload?.length) return null;
  return (
    <div
      className="rounded-md border px-3 py-2 text-xs"
      style={{ background: COLORS.panel, borderColor: COLORS.panelBorder }}
    >
      <div className="mb-1 font-semibold text-white">{label}</div>
      {payload.map((p) => (
        <div key={p.name} className="flex items-center justify-between gap-3">
          <span style={{ color: p.color }}>{p.name}</span>
          <span className="font-medium text-white">
            {p.name === "Total da Venda"
              ? `R$ ${p.value.toLocaleString("pt-BR", {
                  minimumFractionDigits: 2,
                })} Mi`
              : pct(p.value)}
          </span>
        </div>
      ))}
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* Página                                                              */
/* ------------------------------------------------------------------ */
export default function Home() {
  const maxPlataforma = Math.max(...PLATAFORMAS.map((p) => p.valor));

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
            {VENDAS_DIARIAS.map((v) => (
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
        {/* SEÇÃO 1 — KPIs do topo */}
        <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-3">
          <Panel>
            <div className="text-xs uppercase tracking-wider" style={{ color: COLORS.muted }}>
              Total da Venda
            </div>
            <div className="mt-1 text-2xl font-bold" style={{ color: COLORS.green }}>
              {brl(KPIS.totalVenda)}
            </div>
          </Panel>
          <Panel>
            <div className="text-xs uppercase tracking-wider" style={{ color: COLORS.muted }}>
              Total de Pedidos
            </div>
            <div className="mt-1 text-2xl font-bold text-white">{num(KPIS.totalPedidos)}</div>
          </Panel>
          <Panel>
            <div className="text-xs uppercase tracking-wider" style={{ color: COLORS.muted }}>
              Ticket Médio
            </div>
            <div className="mt-1 text-2xl font-bold" style={{ color: COLORS.cyan }}>
              {brl(KPIS.ticketMedio)}
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
                    {brl(PROVAVEL.mediaVendaDiaria)}
                  </div>
                  <div className="mt-2 text-[10px] uppercase" style={{ color: COLORS.muted }}>
                    Fat. Corrente Provável
                  </div>
                  <div className="text-sm font-semibold text-white">
                    {brl(PROVAVEL.faturamentoCorrenteProvavel)}
                  </div>
                </StatCircle>

                <StatCircle accent={COLORS.green}>
                  <div className="text-[10px] uppercase" style={{ color: COLORS.muted }}>
                    MC Ideal
                  </div>
                  <div className="text-base font-bold" style={{ color: COLORS.green }}>
                    {brl(PROVAVEL.mcIdeal)}
                  </div>
                  <div className="mt-2 text-[10px] uppercase" style={{ color: COLORS.muted }}>
                    Ponto de Equilíbrio
                  </div>
                  <div className="text-sm font-semibold text-white">
                    {brl(PROVAVEL.pontoEquilibrio)}
                  </div>
                  <div className="text-xs font-bold" style={{ color: COLORS.green }}>
                    {pct(PROVAVEL.pontoEquilibrioPct)}
                  </div>
                </StatCircle>
              </div>

              <div className="mt-6 flex gap-3">
                <MiniKpi label="% Ret. L Médio" value={pct(PROVAVEL.retLMedio)} accent={COLORS.cyan} />
                <MiniKpi label="% MC L Média" value={pct(PROVAVEL.mcLMedia)} accent={COLORS.green} />
                <MiniKpi label="% MC L Últ Mês" value={pct(PROVAVEL.mcLUltMes)} accent={COLORS.red} />
              </div>
            </Panel>

            {/* SEÇÃO 4 — Total Mensal */}
            <Panel title="Total Mensal">
              <div className="h-72 w-full">
                <ResponsiveContainer width="100%" height="100%">
                  <ComposedChart data={TOTAL_MENSAL} margin={{ top: 10, right: 10, bottom: 0, left: -10 }}>
                    <CartesianGrid stroke={COLORS.panelBorder} vertical={false} />
                    <XAxis dataKey="mes" tick={{ fill: COLORS.muted, fontSize: 12 }} axisLine={false} tickLine={false} />
                    <YAxis
                      yAxisId="venda"
                      tick={{ fill: COLORS.muted, fontSize: 11 }}
                      axisLine={false}
                      tickLine={false}
                      tickFormatter={(v) => `${v} Mi`}
                    />
                    <YAxis
                      yAxisId="pct"
                      orientation="right"
                      tick={{ fill: COLORS.muted, fontSize: 11 }}
                      axisLine={false}
                      tickLine={false}
                      tickFormatter={(v) => `${v}%`}
                    />
                    <Tooltip content={<ChartTooltip />} cursor={{ fill: "#ffffff08" }} />
                    <Bar
                      yAxisId="venda"
                      dataKey="venda"
                      name="Total da Venda"
                      fill={COLORS.cyan}
                      radius={[4, 4, 0, 0]}
                      barSize={36}
                    />
                    <Line
                      yAxisId="pct"
                      type="monotone"
                      dataKey="mcVenda"
                      name="% MC Venda"
                      stroke={COLORS.green}
                      strokeWidth={2}
                      dot={{ r: 3, fill: COLORS.green }}
                    />
                    <Line
                      yAxisId="pct"
                      type="monotone"
                      dataKey="mcLiquida"
                      name="% MC Líquida"
                      stroke={COLORS.red}
                      strokeWidth={2}
                      dot={{ r: 3, fill: COLORS.red }}
                    />
                  </ComposedChart>
                </ResponsiveContainer>
              </div>
              <div className="mt-3 flex flex-wrap justify-center gap-5 text-xs">
                <LegendDot color={COLORS.cyan} label="Total da Venda" />
                <LegendDot color={COLORS.green} label="% MC Venda" />
                <LegendDot color={COLORS.red} label="% MC Líquida" />
              </div>
            </Panel>
          </div>

          {/* ----- COLUNA DIREITA ----- */}
          <div className="space-y-6 lg:col-span-5">
            {/* SEÇÃO 3 — Gauge */}
            <Panel title="Margem de Contribuição Provável">
              <SemiGauge value={GAUGE.valor} max={GAUGE.max} />
              <div className="mt-4 grid grid-cols-5 gap-2">
                {MC_MENSAL.map((m, i) => (
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
            </Panel>

            {/* SEÇÃO 5 — Total por Plataforma */}
            <Panel title="Total por Plataforma">
              <ul className="space-y-3">
                {PLATAFORMAS.map((p) => (
                  <li key={p.nome}>
                    <div className="mb-1 flex items-center justify-between text-xs">
                      <span className="text-white">{p.nome}</span>
                      <span style={{ color: COLORS.muted }}>{brl(p.valor)}</span>
                    </div>
                    <div className="h-2.5 w-full overflow-hidden rounded-full" style={{ background: COLORS.bg }}>
                      <div
                        className="h-full rounded-full"
                        style={{
                          width: `${Math.max((p.valor / maxPlataforma) * 100, 1.5)}%`,
                          background: `linear-gradient(90deg, ${COLORS.cyan}, ${COLORS.green})`,
                        }}
                      />
                    </div>
                  </li>
                ))}
              </ul>
            </Panel>
          </div>
        </div>
      </main>
    </div>
  );
}

function LegendDot({ color, label }: { color: string; label: string }) {
  return (
    <span className="flex items-center gap-1.5" style={{ color: COLORS.muted }}>
      <span className="inline-block h-2.5 w-2.5 rounded-full" style={{ background: color }} />
      {label}
    </span>
  );
}
