"use client";

import {
  ResponsiveContainer,
  ComposedChart,
  Bar,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
} from "recharts";
import type { SerieDiariaItem } from "@/lib/data/types";
import { COLORS, Panel, Na, brl } from "./ui";

const kFmt = (v: number) =>
  "R$ " + (v / 1000).toLocaleString("pt-BR", { maximumFractionDigits: 0 }) + "k";

function TooltipDiario({
  active,
  payload,
  label,
}: {
  active?: boolean;
  payload?: Array<{ name: string; value: number; color: string }>;
  label?: string;
}) {
  if (!active || !payload || payload.length === 0) return null;
  return (
    <div
      className="rounded-lg border px-3 py-2 text-xs"
      style={{ background: COLORS.panel, borderColor: COLORS.panelBorder }}
    >
      <div className="mb-1 font-semibold text-white">{label}</div>
      {payload.map((p) => (
        <div key={p.name} className="flex items-center justify-between gap-4">
          <span style={{ color: p.color }}>{p.name}</span>
          <span className="tabular-nums text-white">{brl(p.value)}</span>
        </div>
      ))}
    </div>
  );
}

export function GraficoDiario({ serie }: { serie: SerieDiariaItem[] }) {
  return (
    <Panel title="Mercado Livre — Faturamento e M.C. por dia">
      {serie.length === 0 ? (
        <div className="py-12 text-center">
          <Na />
        </div>
      ) : (
        <div style={{ width: "100%", height: 300 }}>
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
                yAxisId="fat"
                tick={{ fill: COLORS.muted, fontSize: 10 }}
                tickLine={false}
                axisLine={false}
                tickFormatter={kFmt}
                width={52}
              />
              <YAxis
                yAxisId="mc"
                orientation="right"
                tick={{ fill: COLORS.muted, fontSize: 10 }}
                tickLine={false}
                axisLine={false}
                tickFormatter={kFmt}
                width={52}
              />
              <Tooltip content={<TooltipDiario />} cursor={{ fill: `${COLORS.cyan}12` }} />
              <Legend
                wrapperStyle={{ fontSize: 11, color: COLORS.muted }}
                iconType="circle"
              />
              <Bar
                yAxisId="fat"
                dataKey="faturamento"
                name="Faturamento"
                fill={COLORS.cyan}
                fillOpacity={0.55}
                radius={[3, 3, 0, 0]}
                maxBarSize={22}
              />
              <Line
                yAxisId="mc"
                type="monotone"
                dataKey="mc"
                name="M.C."
                stroke={COLORS.green}
                strokeWidth={2}
                dot={{ r: 2, fill: COLORS.green }}
                activeDot={{ r: 4 }}
              />
            </ComposedChart>
          </ResponsiveContainer>
        </div>
      )}
      <div className="mt-2 text-[10px]" style={{ color: COLORS.muted }}>
        M.C. diária = contribuição direta do dia (fat − CMV − comissão − frete − ADS) com rateio
        proporcional dos custos mensais; a soma bate com a M.C. do mês do card ML.
      </div>
    </Panel>
  );
}
