"use client";

import { DreTable } from "@/components/DreTable";
import { COLORS, Panel } from "@/components/ui";

export default function DrePage() {
  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-bold text-white">D.R.E — Demonstrativo de Resultados</h1>
        <p className="mt-1 text-sm" style={{ color: COLORS.muted }}>
          Fechamento oficial do mês fechado. Topo (Receita → M.C.) consolidado dos canais
          do Hub; Grupo R (despesas) da Omie. Clique numa linha para ver a subdivisão.
        </p>
      </div>
      <Panel>
        <DreTable />
      </Panel>
    </div>
  );
}
