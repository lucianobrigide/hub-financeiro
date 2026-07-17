"use client";

import { useEffect, useState } from "react";
import { useDashboard } from "./DashboardProvider";
import { fetchDreSkuAction } from "@/app/actions";
import type { SkuDre } from "@/lib/data/types";
import { GraficoDiarioDetalhado } from "./GraficoDiarioDetalhado";
import { COLORS, Panel, Na, brl, pct } from "./ui";

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
                  <th className="py-2 text-right text-[10px] font-semibold uppercase tracking-wider">M.C. produto</th>
                  <th className="py-2 text-right text-[10px] font-semibold uppercase tracking-wider">MC %</th>
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
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
        <div className="mt-2 text-[10px]" style={{ color: COLORS.muted }}>
          M.C. de produto = Faturamento − CMV − Comissão − Frete − ADS (antes do overhead do canal) — serve pra decidir
          preço e investimento por SKU. No ML: comissão (sale_fee), frete (envio rateado no pedido) e ADS (gasto real por
          item) são reais; nos demais canais comissão/frete são rateados ∝ faturamento e ADS ainda não é por SKU. Clique
          num SKU para ver o diário.
        </div>
      </Panel>

      {selecionado && (
        <GraficoDiarioDetalhado
          serie={selecionado.serie}
          titulo={`SKU ${selecionado.sku} — ${selecionado.titulo} · composição por dia`}
        />
      )}
    </div>
  );
}
