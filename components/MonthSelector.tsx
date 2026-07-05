"use client";

import { useDashboard } from "./DashboardProvider";
import { COLORS } from "./ui";
import type { ChangeEvent } from "react";

export function MonthSelector() {
  const { month, months, isPending, changeMonth } = useDashboard();

  return (
    <div className="flex items-center gap-3">
      {isPending && (
        <span className="text-xs" style={{ color: COLORS.cyan }}>
          Carregando…
        </span>
      )}
      <select
        aria-label="Selecionar mês"
        value={month}
        onChange={(e: ChangeEvent<HTMLSelectElement>) => changeMonth(e.target.value)}
        disabled={isPending || months.length === 0}
        className="rounded-lg border px-3 py-2 text-sm font-medium outline-none disabled:opacity-60"
        style={{ background: COLORS.panel, borderColor: COLORS.panelBorder, color: COLORS.white }}
      >
        {months.length === 0 && <option value="">Mês atual</option>}
        {months.map((m) => (
          <option key={m.value} value={m.value} style={{ background: COLORS.panel }}>
            {m.label}
          </option>
        ))}
      </select>
    </div>
  );
}
