"use client";

import { DreTable } from "@/components/DreTable";
import { COLORS, Panel } from "@/components/ui";

export default function DrePage() {
  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-bold text-white">D.R.E — Demonstrativo de Resultados</h1>
        <p className="mt-1 text-sm" style={{ color: COLORS.muted }}>
          Estrutura do fechamento oficial. Grupo R (despesas da Omie) preenchido para o
          mês fechado; a metade de cima (Receita → M.C.) vem do Hub e entra em breve.
        </p>
      </div>
      <Panel>
        <DreTable />
      </Panel>
    </div>
  );
}
