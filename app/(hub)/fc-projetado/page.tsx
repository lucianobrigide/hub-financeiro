"use client";

import { useState, useMemo } from "react";
import { COLORS, brl, Panel } from "@/components/ui";
import { getFluxoCaixaMock } from "./mock";
import type { Granularidade, FluxoPeriodo } from "./types";

const GRANULARIDADES: { value: Granularidade; label: string }[] = [
  { value: "dia", label: "Dia" },
  { value: "semana", label: "Semana" },
  { value: "mes", label: "Mês" },
];

function formatPeriodo(p: FluxoPeriodo, g: Granularidade): string {
  const fmt = (iso: string) => {
    const [y, m, d] = iso.split("-");
    return `${d}/${m}`;
  };
  if (g === "dia") return fmt(p.inicio);
  return `${fmt(p.inicio)} — ${fmt(p.fim)}`;
}

export default function FluxoCaixaPage() {
  const [granularidade, setGranularidade] = useState<Granularidade>("dia");
  const data = useMemo(() => getFluxoCaixaMock(granularidade), [granularidade]);

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h2 className="text-base font-bold" style={{ color: COLORS.white }}>
          Fluxo de Caixa Projetado
        </h2>
        <div className="flex gap-1 rounded-lg border p-1" style={{ borderColor: COLORS.panelBorder }}>
          {GRANULARIDADES.map((g) => (
            <button
              key={g.value}
              type="button"
              onClick={() => setGranularidade(g.value)}
              className="rounded-md px-3 py-1 text-xs font-medium transition-colors"
              style={{
                background: granularidade === g.value ? COLORS.cyan : "transparent",
                color: granularidade === g.value ? COLORS.bg : COLORS.muted,
              }}
            >
              {g.label}
            </button>
          ))}
        </div>
      </div>

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Panel>
          <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
            Saldo Inicial
          </div>
          <div className="mt-1 text-lg font-bold" style={{ color: COLORS.white }}>
            {brl(data.saldoInicial)}
          </div>
        </Panel>
        <Panel>
          <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
            Total Entradas
          </div>
          <div className="mt-1 text-lg font-bold" style={{ color: COLORS.green }}>
            {brl(data.totalEntradas)}
          </div>
        </Panel>
        <Panel>
          <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
            Total Saídas
          </div>
          <div className="mt-1 text-lg font-bold" style={{ color: COLORS.red }}>
            {brl(data.totalSaidas)}
          </div>
        </Panel>
        <Panel>
          <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
            Saldo Final
          </div>
          <div className="mt-1 text-lg font-bold" style={{ color: data.saldoFinal >= 0 ? COLORS.green : COLORS.red }}>
            {brl(data.saldoFinal)}
          </div>
        </Panel>
      </div>

      <Panel>
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr
                className="border-b text-left text-[10px] uppercase tracking-wider"
                style={{ borderColor: COLORS.panelBorder, color: COLORS.muted }}
              >
                <th className="pb-2 pr-4 font-medium">Período</th>
                <th className="pb-2 pr-4 text-right font-medium">Entradas</th>
                <th className="pb-2 pr-4 text-right font-medium">Saídas</th>
                <th className="pb-2 pr-4 text-right font-medium">Saldo</th>
                <th className="pb-2 text-right font-medium">Acumulado</th>
              </tr>
            </thead>
            <tbody>
              {data.periodos.map((p) => (
                <tr
                  key={p.inicio}
                  className="border-b transition-colors hover:bg-white/5"
                  style={{ borderColor: COLORS.panelBorder }}
                >
                  <td className="py-2 pr-4" style={{ color: COLORS.white }}>
                    {formatPeriodo(p, granularidade)}
                  </td>
                  <td className="py-2 pr-4 text-right" style={{ color: COLORS.green }}>
                    {brl(p.entradas)}
                  </td>
                  <td className="py-2 pr-4 text-right" style={{ color: COLORS.red }}>
                    {brl(p.saidas)}
                  </td>
                  <td
                    className="py-2 pr-4 text-right font-medium"
                    style={{ color: p.saldo >= 0 ? COLORS.green : COLORS.red }}
                  >
                    {brl(p.saldo)}
                  </td>
                  <td
                    className="py-2 text-right font-medium"
                    style={{ color: p.saldoAcumulado >= 0 ? COLORS.cyan : COLORS.red }}
                  >
                    {brl(p.saldoAcumulado)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Panel>
    </div>
  );
}
