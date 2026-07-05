"use client";

import type { ReactNode } from "react";
import { useDashboard } from "@/components/DashboardProvider";
import { MonthSelector } from "@/components/MonthSelector";
import { COLORS } from "@/components/ui";

export function HubMain({ children }: { children: ReactNode }) {
  const { isPending, month, months } = useDashboard();

  return (
    <main className="flex-1 overflow-y-auto p-6">
      <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-lg font-bold text-white">Hub Financeiro</h2>
          <p className="text-xs" style={{ color: COLORS.muted }}>
            {months.find((m) => m.value === month)?.label ?? "Mês atual"}
          </p>
        </div>
        <MonthSelector />
      </div>

      <div
        style={{
          opacity: isPending ? 0.5 : 1,
          transition: "opacity 150ms ease",
          pointerEvents: isPending ? "none" : "auto",
        }}
      >
        {children}
      </div>
    </main>
  );
}
