"use client";

import { useEffect, useState } from "react";
import { useDashboard } from "./DashboardProvider";
import { fetchDreSkuAction } from "@/app/actions";
import type { SkuDre } from "@/lib/data/types";
import { GraficoDiarioDetalhado } from "./GraficoDiarioDetalhado";
import { COLORS, Panel, Na, MiniKpi, brl, pct } from "./ui";

export function DreSkuSection({ canalKey }: { canalKey: string }) {
  const { month } = useDashboard();
  const [skus, setSkus] = useState<SkuDre[] | null>(null);
  const [sel, setSel] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let ativo = true;
    setLoading(true);
    fetchDreSkuAction(canalKey, month)
      .then((data) => {
        if (!ativo) return;
        setSkus(data);
        setSel(data[0]?.sku ?? null);
      })
      .finally(() => ativo && setLoading(false));
    return () => {
      ativo = false;
    };
  }, [canalKey, month]);

  const selecionado = skus?.find((s) => s.sku === sel) ?? null;
  // Coluna "Subsídio" só aparece onde ela existe de fato (hoje só SHEIN) — nos demais
  // canais seria uma coluna de zeros.
  const temSubsidio = (skus ?? []).some((s) => (s.subsidio ?? 0) !== 0);

  return (
    <div className="mt-6 space-y-4">
      <Panel title="DRE por SKU — Faturamento, CMV, Comissão e M.C. de produto">
        {loading ? (
          <div className="py-8 text-center text-xs" style={{ color: COLORS.muted }}>
            Carregando SKUs…
          </div>
        ) : !skus || skus.length === 0 ? (
          <div className="py-8 text-center">
            <Na />
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full border-collapse text-sm">
              <thead>
                <tr style={{ color: COLORS.muted }}>
                  <th className="py-2 text-left text-[10px] font-semibold uppercase tracking-wider">SKU</th>
                  <th className="py-2 text-right text-[10px] font-semibold uppercase tracking-wider">Faturamento</th>
                  <th className="py-2 text-right text-[10px] font-semibold uppercase tracking-wider">CMV</th>
                  <th className="py-2 text-right text-[10px] font-semibold uppercase tracking-wider">Comissão</th>
                  <th className="py-2 text-right text-[10px] font-semibold uppercase tracking-wider">Frete</th>
                  <th className="py-2 text-right text-[10px] font-semibold uppercase tracking-wider">ADS</th>
                  {temSubsidio && (
                    <th className="py-2 text-right text-[10px] font-semibold uppercase tracking-wider">Subsídio</th>
                  )}
                  <th className="py-2 text-right text-[10px] font-semibold uppercase tracking-wider">M.C. produto</th>
                  <th className="py-2 text-right text-[10px] font-semibold uppercase tracking-wider">MC %</th>
                  <th className="py-2 text-right text-[10px] font-semibold uppercase tracking-wider">ROAS</th>
                </tr>
              </thead>
              <tbody>
                {skus.slice(0, 25).map((s) => {
                  const ativo = s.sku === sel;
                  return (
                    <tr
                      key={s.sku}
                      onClick={() => setSel(s.sku)}
                      className="cursor-pointer"
                      style={{
                        borderTop: `1px solid ${COLORS.panelBorder}`,
                        background: ativo ? `${COLORS.cyan}12` : undefined,
                      }}
                    >
                      <td className="py-1.5 pr-2">
                        <div className="font-semibold" style={{ color: ativo ? COLORS.cyan : COLORS.white }}>
                          {s.sku}
                        </div>
                        <div className="max-w-[240px] truncate text-[10px]" style={{ color: COLORS.muted }}>
                          {s.titulo}
                        </div>
                      </td>
                      <td className="py-1.5 text-right tabular-nums text-white">{brl(s.faturamento)}</td>
                      <td className="py-1.5 text-right tabular-nums" style={{ color: COLORS.muted }}>{brl(s.cmv)}</td>
                      <td className="py-1.5 text-right tabular-nums" style={{ color: COLORS.muted }}>{brl(s.comissao)}</td>
                      <td className="py-1.5 text-right tabular-nums" style={{ color: COLORS.muted }}>{brl(s.frete)}</td>
                      <td className="py-1.5 text-right tabular-nums" style={{ color: COLORS.muted }}>{brl(s.ads)}</td>
                      {temSubsidio && (
                        <td className="py-1.5 text-right tabular-nums" style={{ color: COLORS.green }}>
                          {brl(-(s.subsidio ?? 0))}
                        </td>
                      )}
                      <td
                        className="py-1.5 text-right font-semibold tabular-nums"
                        style={{ color: s.mc < 0 ? COLORS.red : COLORS.green }}
                      >
                        {brl(s.mc)}
                      </td>
                      <td
                        className="py-1.5 text-right tabular-nums"
                        style={{ color: s.mc < 0 ? COLORS.red : COLORS.green }}
                      >
                        {s.mcPct == null ? "—" : pct(s.mcPct)}
                      </td>
                      <td
                        className="py-1.5 text-right font-semibold tabular-nums"
                        style={{
                          color:
                            s.ads <= 0
                              ? COLORS.muted
                              : s.faturamento / s.ads >= 4
                                ? COLORS.green
                                : s.faturamento / s.ads < 2
                                  ? COLORS.red
                                  : COLORS.white,
                        }}
                      >
                        {s.ads <= 0
                          ? "—"
                          : (s.faturamento / s.ads).toLocaleString("pt-BR", { maximumFractionDigits: 1 }) + "×"}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
        <div className="mt-2 text-[10px]" style={{ color: COLORS.muted }}>
          M.C. de produto = Faturamento − CMV − Comissão − Frete − ADS + Subsídio (antes do overhead do canal) — serve pra decidir
          preço e investimento por SKU. No ML: comissão (sale_fee), frete (envio rateado no pedido) e ADS (gasto real por
          item) são reais; nos demais canais comissão/frete são rateados ∝ faturamento e ADS ainda não é por SKU. Clique
          num SKU para ver o diário.
        </div>
      </Panel>

      {selecionado && (
        <>
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-5">
            <MiniKpi label="Faturamento" value={brl(selecionado.faturamento)} accent={COLORS.white} />
            <MiniKpi
              label="M.C. produto"
              value={brl(selecionado.mc)}
              accent={selecionado.mc < 0 ? COLORS.red : COLORS.green}
            />
            <MiniKpi
              label="MC %"
              value={selecionado.mcPct == null ? "—" : pct(selecionado.mcPct)}
              accent={selecionado.mc < 0 ? COLORS.red : COLORS.green}
            />
            <MiniKpi label="ADS" value={brl(selecionado.ads)} accent={COLORS.cyan} />
            <MiniKpi
              label="ROAS (fat ÷ ADS)"
              value={
                selecionado.ads <= 0
                  ? "s/ ADS"
                  : (selecionado.faturamento / selecionado.ads).toLocaleString("pt-BR", {
                      maximumFractionDigits: 1,
                    }) + "×"
              }
              accent={
                selecionado.ads <= 0
                  ? COLORS.muted
                  : selecionado.faturamento / selecionado.ads >= 4
                    ? COLORS.green
                    : selecionado.faturamento / selecionado.ads < 2
                      ? COLORS.red
                      : COLORS.white
              }
            />
          </div>
          <GraficoDiarioDetalhado
            serie={selecionado.serie}
            titulo={`SKU ${selecionado.sku} — ${selecionado.titulo} · composição por dia`}
          />
        </>
      )}
    </div>
  );
}
