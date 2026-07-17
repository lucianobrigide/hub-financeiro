"use client";

import type { PlataformaDre } from "@/lib/data/types";
import { COLORS, Panel, Na, brl, pct } from "./ui";

export function PlataformaDreCard({ p }: { p: PlataformaDre }) {
  // Base de TODOS os percentuais = Faturamento Líquido (análise vertical do mini-DRE:
  // deduções% + M.C.% = 100% do líquido).
  const base = p.faturamentoLiquido;
  const pctLiq = (v: number | null): number | null =>
    v != null && base != null && base !== 0 ? (v / base) * 100 : null;
  const mcPct = pctLiq(p.mc);

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

        <div className="mt-3 flex justify-between text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
          <span>Deduções</span>
          <span>% do líquido</span>
        </div>
        <div className="mt-1 space-y-1 text-xs" style={{ color: COLORS.muted }}>
          {p.deducoes.map((d) => {
            const dp = pctLiq(d.valor);
            return (
              <div key={d.label} className="pl-3">
                <div className="flex justify-between">
                  <span>{d.label}</span>
                  <span className="whitespace-nowrap">
                    {d.valor == null ? (
                      <Na small />
                    ) : (
                      <>
                        {brl(d.valor)}
                        {dp != null && (
                          <span className="ml-1 tabular-nums text-[10px]" style={{ color: COLORS.cyan }}>
                            {pct(dp)}
                          </span>
                        )}
                      </>
                    )}
                  </span>
                </div>
                {d.nota && (
                  <div className="text-right text-[9px] italic" style={{ color: COLORS.cyan }}>
                    {d.nota}
                  </div>
                )}
              </div>
            );
          })}
        </div>

        <div
          className="mt-3 flex items-center justify-between border-t pt-2 text-base font-bold"
          style={{
            borderColor: COLORS.panelBorder,
            color: p.mc != null && p.mc < 0 ? COLORS.red : COLORS.green,
          }}
        >
          <span>M.C. (Margem de Contribuição)</span>
          <span className="shrink-0 whitespace-nowrap pl-2">
            {p.mc == null ? (
              <Na small />
            ) : (
              <>
                {brl(p.mc)}
                {mcPct != null && (
                  <span className="ml-1 text-xs font-semibold">{pct(mcPct)}</span>
                )}
              </>
            )}
          </span>
        </div>
      </div>
    </Panel>
  );
}
