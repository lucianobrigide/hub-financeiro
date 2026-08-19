"use client";

import {
  ResponsiveContainer,
  ComposedChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
} from "recharts";
import type { SerieDiariaItem } from "@/lib/data/types";
import { COLORS, Panel, Na, brl, pct } from "./ui";

// Composição do dia (empilhada): despesas + M.C. somam o faturamento.
// "Subsídio" é CRÉDITO — vem negativo da série e empilha abaixo do eixo.
const SEGMENTOS = [
  { key: "cmv", label: "CMV", cor: "#ff9f1c" },
  { key: "comissao", label: "Comissão", cor: "#9d4edd" },
  { key: "frete", label: "Frete", cor: "#4895ef" },
  { key: "ads", label: "ADS", cor: "#f72585" },
  { key: "subsidio", label: "Subsídio", cor: "#2ec4b6" },
  { key: "outras", label: "Outras", cor: "#6c757d" },
  { key: "mc", label: "M.C.", cor: COLORS.green },
] as const;

const kFmt = (v: number) =>
  "R$ " + (v / 1000).toLocaleString("pt-BR", { maximumFractionDigits: 0 }) + "k";

function TooltipDetalhe({
  active,
  payload,
  label,
}: {
  active?: boolean;
  payload?: Array<{ name: string; value: number; color: string }>;
  label?: string;
}) {
  if (!active || !payload || payload.length === 0) return null;
  const fat = payload.reduce((s, p) => s + (p.value || 0), 0);
  return (
    <div
      className="rounded-lg border px-3 py-2 text-xs"
      style={{ background: COLORS.panel, borderColor: COLORS.panelBorder }}
    >
      <div className="mb-1 flex justify-between gap-6 font-semibold text-white">
        <span>{label} · Faturamento</span>
        <span className="tabular-nums">{brl(fat)}</span>
      </div>
      {payload.map((p) => (
        <div key={p.name} className="flex items-center justify-between gap-4">
          <span style={{ color: p.color }}>{p.name}</span>
          <span className="tabular-nums text-white">
            {brl(p.value)}
            {fat !== 0 && (
              <span className="ml-1" style={{ color: COLORS.muted }}>
                {pct((p.value / fat) * 100)}
              </span>
            )}
          </span>
        </div>
      ))}
    </div>
  );
}

export function GraficoDiarioDetalhado({
  serie,
  titulo,
}: {
  serie: SerieDiariaItem[];
  titulo: string;
}) {
  return (
    <Panel title={titulo}>
      {serie.length === 0 ? (
        <div className="py-12 text-center">
          <Na />
        </div>
      ) : (
        <div style={{ width: "100%", height: 320 }}>
          <ResponsiveContainer>
            <ComposedChart data={serie} margin={{ top: 8, right: 8, bottom: 0, left: 8 }}>
              <CartesianGrid strokeDasharray="3 3" stroke={COLORS.panelBorder} vertical={false} />
              <XAxis
                dataKey="data"
                tick={{ fill: COLORS.muted, fontSize: 10 }}
                tickLine={false}
                axisLine={{ stroke: COLORS.panelBorder }}
                interval="preserveStartEnd"
                minTickGap={12}
              />
              <YAxis
                tick={{ fill: COLORS.muted, fontSize: 10 }}
                tickLine={false}
                axisLine={false}
                tickFormatter={kFmt}
                width={52}
              />
              <Tooltip content={<TooltipDetalhe />} cursor={{ fill: `${COLORS.cyan}12` }} />
              <Legend wrapperStyle={{ fontSize: 11, color: COLORS.muted }} iconType="circle" />
              {SEGMENTOS.map((s) => (
                <Bar
                  key={s.key}
                  dataKey={s.key}
                  name={s.label}
                  stackId="dre"
                  fill={s.cor}
                  fillOpacity={s.key === "mc" ? 0.95 : 0.8}
                  maxBarSize={26}
                />
              ))}
            </ComposedChart>
          </ResponsiveContainer>
        </div>
      )}
      <div className="mt-2 text-[10px]" style={{ color: COLORS.muted }}>
        Cada barra = faturamento do dia decomposto: despesas reais (CMV, comissão, frete, ADS) +
        &ldquo;Outras&rdquo; (custos de ciclo mensal rateados) + a M.C. no topo.
        &ldquo;Subsídio&rdquo; aparece abaixo do eixo por ser crédito da plataforma (SHEIN:
        desconto de promoção que ela banca — o repasse é calculado sobre uma base maior que o
        preço pago pelo cliente).
      </div>
    </Panel>
  );
}
