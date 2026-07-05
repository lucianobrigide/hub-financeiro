"use client";

import { COLORS, Panel } from "./ui";

export function Placeholder({ title }: { title: string }) {
  return (
    <Panel>
      <div className="flex flex-col items-center justify-center py-16 text-center">
        <div
          className="mb-3 text-4xl"
          style={{ color: COLORS.panelBorder }}
        >
          ◻
        </div>
        <h3 className="text-lg font-semibold text-white">{title}</h3>
        <p className="mt-2 text-sm" style={{ color: COLORS.muted }}>
          Em construção — disponível em breve.
        </p>
      </div>
    </Panel>
  );
}
