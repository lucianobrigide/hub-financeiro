"use client";

import { useDashboard } from "@/components/DashboardProvider";
import { DashboardBody } from "@/components/DashboardBody";
import { DreSkuSection } from "@/components/DreSkuSection";
import { COLORS } from "@/components/ui";

// Slug da rota → chave curta do canal no RPC dre_sku.
const CANAL_KEY: Record<string, string> = {
  "mercado-livre": "ml",
  shopee: "sp",
  tiktok: "tt",
  amazon: "az",
  "vendas-internas": "b2b",
};

/** Dashboard completo isolado de um canal (aberto pelo "Ver mais" dos cards). */
export function CanalDashboard({ id }: { id: string }) {
  const { data } = useDashboard();
  const canal = data.porCanal.find((c) => c.id === id);

  if (!canal) {
    return (
      <p className="text-sm" style={{ color: COLORS.muted }}>
        Sem dados para este canal neste mês.
      </p>
    );
  }

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-bold text-white">{canal.nome}</h1>
        <p className="text-xs" style={{ color: COLORS.muted }}>
          Dashboard isolado do canal
        </p>
      </div>
      <DashboardBody
        kpis={canal.kpis}
        meta={canal.meta}
        provavel={canal.provavel}
        serieDiaria={canal.serieDiaria}
        cards={[{ dre: canal.dre }]}
        escopo={canal.nome}
        tituloGrafico={`${canal.nome} — Despesas, M.C. e Faturamento por dia`}
        detalharDespesas
      />
      {CANAL_KEY[canal.id] && <DreSkuSection canalKey={CANAL_KEY[canal.id]} />}
    </div>
  );
}
