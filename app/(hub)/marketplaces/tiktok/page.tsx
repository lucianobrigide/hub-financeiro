"use client";

import { useDashboard } from "@/components/DashboardProvider";
import { PlataformaDreCard } from "@/components/PlataformaDreCard";
import { COLORS } from "@/components/ui";

export default function TikTokPage() {
  const { data } = useDashboard();
  const dre = data.plataformasDre.find((p) => p.nome === "TikTok Shop");

  if (!dre) {
    return (
      <p className="text-sm" style={{ color: COLORS.muted }}>
        Sem dados para TikTok Shop neste mês.
      </p>
    );
  }

  return (
    <div className="max-w-xl">
      <PlataformaDreCard p={dre} />
    </div>
  );
}
