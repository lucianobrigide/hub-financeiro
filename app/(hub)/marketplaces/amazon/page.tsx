"use client";

import { useDashboard } from "@/components/DashboardProvider";
import { PlataformaDreCard } from "@/components/PlataformaDreCard";
import { COLORS } from "@/components/ui";

export default function AmazonPage() {
  const { data } = useDashboard();
  const dre = data.plataformasDre.find((p) => p.nome === "Amazon");

  if (!dre) {
    return (
      <p className="text-sm" style={{ color: COLORS.muted }}>
        Sem dados para Amazon neste mês.
      </p>
    );
  }

  return (
    <div className="max-w-xl">
      <PlataformaDreCard p={dre} />
    </div>
  );
}
