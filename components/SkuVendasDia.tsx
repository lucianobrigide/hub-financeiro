"use client";

import { useEffect, useMemo, useState } from "react";
import { useDashboard } from "./DashboardProvider";
import { fetchSkuVendasDiaAction } from "@/app/actions";
import type { SkuVendaDia } from "@/lib/data/types";
import { COLORS, Na, Panel, num } from "./ui";

// Tabela SKU × dia do dashboard principal: unidades vendidas por SKU em cada dia
// (todos os canais somados). O mês vem do seletor global; o filtro de dias é local.
export function SkuVendasDia() {
  const { month } = useDashboard();
  const [linhas, setLinhas] = useState<SkuVendaDia[] | null>(null);
  const [loading, setLoading] = useState(true);
  // Filtro de dias (índices na lista de dias do mês). null = mês inteiro.
  const [de, setDe] = useState<string | null>(null);
  const [ate, setAte] = useState<string | null>(null);

  useEffect(() => {
    let ativo = true;
    setLoading(true);
    fetchSkuVendasDiaAction(month)
      .then((data) => {
        if (!ativo) return;
        setLinhas(data);
        setDe(null);
        setAte(null);
      })
      .finally(() => ativo && setLoading(false));
    return () => {
      ativo = false;
    };
  }, [month]);

  // Dias do mês presentes no dado, em ordem ("DD/MM" → ordena pelo dia).
  const dias = useMemo(() => {
    const set = new Set((linhas ?? []).map((l) => l.data));
    return Array.from(set).sort((a, b) => Number(a.split("/")[0]) - Number(b.split("/")[0]));
  }, [linhas]);

  const idxDe = de && dias.includes(de) ? dias.indexOf(de) : 0;
  const idxAteRaw = ate && dias.includes(ate) ? dias.indexOf(ate) : dias.length - 1;
  const idxAte = Math.max(idxDe, idxAteRaw); // "até" nunca antes do "de"
  const colunas = dias.slice(idxDe, idxAte + 1);

  // Agrega por SKU dentro do recorte de dias; SKU sem venda no recorte sai da lista.
  const { skus, totalPorDia, totalGeral } = useMemo(() => {
    const cols = new Set(colunas);
    const map = new Map<string, { titulo: string; porDia: Map<string, number>; total: number }>();
    const totDia = new Map<string, number>();
    let tot = 0;
    for (const l of linhas ?? []) {
      if (!cols.has(l.data)) continue;
      const cur = map.get(l.sku) ?? { titulo: l.titulo ?? l.sku, porDia: new Map(), total: 0 };
      cur.porDia.set(l.data, (cur.porDia.get(l.data) ?? 0) + l.qtd);
      cur.total += l.qtd;
      if (l.titulo && (!cur.titulo || cur.titulo === l.sku)) cur.titulo = l.titulo;
      map.set(l.sku, cur);
      totDia.set(l.data, (totDia.get(l.data) ?? 0) + l.qtd);
      tot += l.qtd;
    }
    const arr = Array.from(map.entries())
      .map(([sku, v]) => ({ sku, ...v }))
      .filter((s) => s.total > 0)
      .sort((a, b) => b.total - a.total);
    return { skus: arr, totalPorDia: totDia, totalGeral: tot };
  }, [linhas, colunas]);

  const selectStyle = {
    background: COLORS.bg,
    border: `1px solid ${COLORS.panelBorder}`,
    color: COLORS.white,
  } as const;

  return (
    <div className="mt-6">
      <Panel title="Vendas por SKU × dia — unidades, todos os canais">
        {loading ? (
          <div className="py-8 text-center text-xs" style={{ color: COLORS.muted }}>
            Carregando vendas por SKU…
          </div>
        ) : dias.length === 0 ? (
          <div className="py-8 text-center">
            <Na />
          </div>
        ) : (
          <>
            <div className="mb-3 flex flex-wrap items-center gap-2 text-xs" style={{ color: COLORS.muted }}>
              <span>Dias:</span>
              <select
                className="rounded px-2 py-1 text-xs"
                style={selectStyle}
                value={dias[idxDe]}
                onChange={(e) => setDe(e.target.value)}
              >
                {dias.map((d) => (
                  <option key={d} value={d}>{d}</option>
                ))}
              </select>
              <span>até</span>
              <select
                className="rounded px-2 py-1 text-xs"
                style={selectStyle}
                value={dias[idxAte]}
                onChange={(e) => setAte(e.target.value)}
              >
                {dias.map((d) => (
                  <option key={d} value={d}>{d}</option>
                ))}
              </select>
              {(idxDe > 0 || idxAte < dias.length - 1) && (
                <button
                  className="cursor-pointer rounded px-2 py-1 text-xs"
                  style={{ ...selectStyle, color: COLORS.cyan }}
                  onClick={() => {
                    setDe(null);
                    setAte(null);
                  }}
                >
                  Mês todo
                </button>
              )}
              <span className="ml-auto">
                {num(totalGeral)} unidades · {skus.length} SKUs ·{" "}
                {colunas.length === 1 ? `dia ${colunas[0]}` : `${colunas[0]} a ${colunas[colunas.length - 1]}`}
              </span>
            </div>

            <div className="overflow-x-auto">
              <table className="w-full border-collapse text-sm">
                <thead>
                  <tr style={{ color: COLORS.muted }}>
                    <th
                      className="sticky left-0 z-10 py-2 pr-3 text-left text-[10px] font-semibold uppercase tracking-wider"
                      style={{ background: COLORS.panel }}
                    >
                      SKU
                    </th>
                    {colunas.map((d) => (
                      <th key={d} className="px-2 py-2 text-right text-[10px] font-semibold tabular-nums">
                        {d}
                      </th>
                    ))}
                    <th className="py-2 pl-3 text-right text-[10px] font-semibold uppercase tracking-wider">
                      Total
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <tr style={{ borderTop: `1px solid ${COLORS.panelBorder}` }}>
                    <td
                      className="sticky left-0 z-10 py-1.5 pr-3 text-[11px] font-semibold uppercase tracking-wider"
                      style={{ background: COLORS.panel, color: COLORS.cyan }}
                    >
                      Todos os SKUs
                    </td>
                    {colunas.map((d) => (
                      <td key={d} className="px-2 py-1.5 text-right font-semibold tabular-nums" style={{ color: COLORS.cyan }}>
                        {num(totalPorDia.get(d) ?? 0)}
                      </td>
                    ))}
                    <td className="py-1.5 pl-3 text-right font-semibold tabular-nums" style={{ color: COLORS.cyan }}>
                      {num(totalGeral)}
                    </td>
                  </tr>
                  {skus.map((s) => (
                    <tr key={s.sku} style={{ borderTop: `1px solid ${COLORS.panelBorder}` }}>
                      <td
                        className="sticky left-0 z-10 max-w-[240px] py-1.5 pr-3"
                        style={{ background: COLORS.panel }}
                      >
                        <div className="truncate font-semibold text-white">{s.sku}</div>
                        <div className="truncate text-[10px]" style={{ color: COLORS.muted }}>
                          {s.titulo}
                        </div>
                      </td>
                      {colunas.map((d) => {
                        const q = s.porDia.get(d) ?? 0;
                        return (
                          <td
                            key={d}
                            className="px-2 py-1.5 text-right tabular-nums"
                            style={{ color: q === 0 ? `${COLORS.muted}66` : COLORS.white }}
                          >
                            {q === 0 ? "—" : num(q)}
                          </td>
                        );
                      })}
                      <td className="py-1.5 pl-3 text-right font-semibold tabular-nums text-white">
                        {num(s.total)}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            <div className="mt-2 text-[10px]" style={{ color: COLORS.muted }}>
              Unidades vendidas somando todos os canais (ML, Shopee, TikTok, Amazon, SHEIN, Magalu e B2B), pelas mesmas
              réguas de status da receita bruta de cada canal. O dia corrente não aparece: os pedidos entram nos crons da
              madrugada. SKUs sem venda no recorte de dias ficam ocultos.
            </div>
          </>
        )}
      </Panel>
    </div>
  );
}
