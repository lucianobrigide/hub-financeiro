"use client";

import { useDashboard } from "@/components/DashboardProvider";
import { PlataformaDreCard } from "@/components/PlataformaDreCard";
import { COLORS } from "@/components/ui";

export default function MercadoLivrePage() {
  const { data } = useDashboard();
  const dre = data.plataformasDre.find((p) => p.nome === "Mercado Livre");

  if (!dre) {
    return (
      <p className="text-sm" style={{ color: COLORS.muted }}>
        Sem dados para Mercado Livre neste mês.
      </p>
    );
  }

  return (
    <div className="max-w-xl">
      <PlataformaDreCard p={dre} />
    </div>
  );
}
