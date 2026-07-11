"use client";

import type { PlataformaDre } from "@/lib/data/types";
import { COLORS, Panel, Na, brl } from "./ui";

export function PlataformaDreCard({ p }: { p: PlataformaDre }) {
  return (
    <Panel>
      <div className="flex h-full flex-col">
        <div className="text-sm font-semibold uppercase tracking-wider text-white">
          {p.nome}
        </div>

        <div className="mt-3 space-y-1 text-xs" style={{ color: COLORS.muted }}>
          <div className="flex justify-between">
            <span>Faturamento Bruto</span>
            <span>{p.faturamentoBruto == null ? <Na small /> : brl(p.faturamentoBruto)}</span>
          </div>
          <div className="flex justify-between">
            <span>(−) Cancel. e Devoluções</span>
            <span>{p.cancelDevolucoes == null ? <Na small /> : brl(p.cancelDevolucoes)}</span>
          </div>
        </div>

        <div
          className="mt-2 flex justify-between border-t pt-2 text-sm font-bold text-white"
          style={{ borderColor: COLORS.panelBorder }}
        >
          <span>Faturamento Líquido</span>
          <span>{p.faturamentoLiquido == null ? <Na small /> : brl(p.faturamentoLiquido)}</span>
        </div>

        <div className="mt-3 text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
          Deduções
        </div>
        <div className="mt-1 space-y-1 text-xs" style={{ color: COLORS.muted }}>
          {p.deducoes.map((d) => (
            <div key={d.label} className="pl-3">
              <div className="flex justify-between">
                <span>{d.label}</span>
                <span>{d.valor == null ? <Na small /> : brl(d.valor)}</span>
              </div>
              {d.nota && (
                <div className="text-right text-[9px] italic" style={{ color: COLORS.cyan }}>
                  {d.nota}
                </div>
              )}
            </div>
          ))}
        </div>

        <div
          className="mt-3 flex items-center justify-between border-t pt-2 text-base font-bold"
          style={{
            borderColor: COLORS.panelBorder,
            color: p.mc != null && p.mc < 0 ? COLORS.red : COLORS.green,
          }}
        >
          <span>M.C. (Margem de Contribuição)</span>
          <span className="shrink-0 whitespace-nowrap pl-2">{p.mc == null ? <Na small /> : brl(p.mc)}</span>
        </div>
      </div>
    </Panel>
  );
}
