"use client";

import { useDashboard } from "@/components/DashboardProvider";
import { DashboardBody } from "@/components/DashboardBody";
import { SkuVendasDia } from "@/components/SkuVendasDia";

// Rótulo do canal (plataformasDre.nome) → slug da rota "Ver mais".
const SLUG: Record<string, string> = {
  "Mercado Livre": "mercado-livre",
  Shopee: "shopee",
  "TikTok Shop": "tiktok",
  Amazon: "amazon",
  SHEIN: "shein",
  Magalu: "magalu",
  B2B: "vendas-internas",
};

export default function OverviewPage() {
  const { data } = useDashboard();

  const cards = data.plataformasDre.map((p) => ({
    dre: p,
    href: SLUG[p.nome] ? `/marketplaces/${SLUG[p.nome]}` : undefined,
  }));

  return (
    <>
      <DashboardBody
        kpis={data.kpis}
        meta={data.meta}
        provavel={data.provavel}
        serieDiaria={data.serieDiaria}
        cards={cards}
        escopo="todos os canais"
        tituloGrafico="Faturamento e M.C. por dia — todos os canais"
      />
      <SkuVendasDia />
    </>
  );
}
